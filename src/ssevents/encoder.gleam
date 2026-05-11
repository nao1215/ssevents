//// Deterministic Server-Sent Events encoding.
////
//// The default line ending is LF. Call the `*_with_line_ending`
//// variants to emit CRLF instead.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import ssevents/event

pub type LineEnding {
  Lf
  Crlf
}

pub fn default_line_ending() -> LineEnding {
  Lf
}

/// Encode one semantic SSE `Event` to its wire-format `String` (LF
/// line ending).
///
/// **Determinism invariant** (#72): the encoded bytes depend only on
/// the *value* of the `Event`, not on the builder call sequence used to
/// construct it. For any two structurally equal `Event` values
/// (`Event.from_parts(...)` with the same fields, or any sequence of
/// builder calls that ends in the same field assignment),
/// `encode(a) == encode(b)` byte-for-byte. The same invariant holds
/// across the BEAM and JavaScript targets, so caches, signatures, and
/// content-addressable storage on the wire are stable across runtimes.
pub fn encode(event: event.Event) -> String {
  encode_with_line_ending(event, Lf)
}

pub fn encode_bytes(event: event.Event) -> BitArray {
  encode(event) |> bit_array.from_string
}

pub fn encode_item(item: event.Item) -> String {
  encode_item_with_line_ending(item, Lf)
}

pub fn encode_item_bytes(item: event.Item) -> BitArray {
  encode_item(item) |> bit_array.from_string
}

pub fn encode_items(items: List(event.Item)) -> String {
  encode_items_with_line_ending(items, Lf)
}

pub fn encode_items_bytes(items: List(event.Item)) -> BitArray {
  encode_items(items) |> bit_array.from_string
}

pub fn encode_with_line_ending(
  event: event.Event,
  line_ending: LineEnding,
) -> String {
  let newline = line_ending_to_string(line_ending)
  let lines = event_lines(event)
  string.concat(list.map(lines, fn(line) { line <> newline })) <> newline
}

pub fn encode_item_with_line_ending(
  item: event.Item,
  line_ending: LineEnding,
) -> String {
  case item {
    event.EventItem(ev) -> encode_with_line_ending(ev, line_ending)
    event.CommentItem(c) ->
      encode_comment_with_line_ending(event.comment_text_of(c), line_ending)
  }
}

pub fn encode_items_with_line_ending(
  items: List(event.Item),
  line_ending: LineEnding,
) -> String {
  items
  |> list.map(fn(item) { encode_item_with_line_ending(item, line_ending) })
  |> string.concat
}

fn event_lines(ev: event.Event) -> List(String) {
  let prefix_lines =
    []
    |> prepend_optional("event", event.name_of(ev))
    |> prepend_optional("id", event.id_of(ev))
    |> prepend_optional_int("retry", event.retry_of(ev))
    |> list.reverse

  // Issue #88: the default decoder rejects lines > 8192 bytes
  // (`LineTooLong(8192)`), so a verbatim `data:` line longer than
  // ~8184 bytes makes `decode(encode(e))` fail outright. The encoder
  // caps each emitted `data:` line at 2000 codepoints (worst-case
  // 8000 bytes for 4-byte UTF-8, comfortably under the limit even
  // after the `data: ` prefix and trailing newline). The WHATWG
  // dispatch rule joins multiple `data:` lines with LF, so this
  // trades byte-perfect round-trip for parseability: the decoded
  // value gets `\n` inserted at chunk boundaries. JSON/base64
  // payloads (the common SSE shapes for >8KB content) tolerate this;
  // callers needing byte-identical fidelity should base64-encode.
  let data_lines =
    event.data_of(ev)
    |> normalise_newlines
    |> string.split(on: "\n")
    |> list.flat_map(chunk_data_line)
    |> list.map(fn(line) { prefixed_line("data", line) })

  list.append(prefix_lines, data_lines)
}

// 2000 codepoints worst-case ≈ 8000 bytes (UTF-8 max 4 B/cp), leaving
// margin under the decoder's 8192-byte line limit even after the
// `data: ` prefix and trailing `\n`. For pure ASCII this means
// `data:` lines top out around 2000 chars rather than the maximum 8185
// the wire allows; round-trip correctness wins over wire density here.
const max_data_line_codepoints = 2000

fn chunk_data_line(line: String) -> List(String) {
  case string.byte_size(line) <= max_data_line_codepoints * 4 {
    True -> [line]
    False -> chunk_data_line_loop(line, [])
  }
}

fn chunk_data_line_loop(remaining: String, acc: List(String)) -> List(String) {
  case string.length(remaining) <= max_data_line_codepoints {
    True -> list.reverse([remaining, ..acc])
    False -> {
      let head =
        string.slice(remaining, at_index: 0, length: max_data_line_codepoints)
      let rest =
        string.slice(
          remaining,
          at_index: max_data_line_codepoints,
          length: string.length(remaining) - max_data_line_codepoints,
        )
      chunk_data_line_loop(rest, [head, ..acc])
    }
  }
}

fn prepend_optional(
  lines: List(String),
  field: String,
  maybe_value: Option(String),
) -> List(String) {
  case maybe_value {
    Some(value) -> [prefixed_line(field, value), ..lines]
    None -> lines
  }
}

fn prepend_optional_int(
  lines: List(String),
  field: String,
  maybe_value: Option(Int),
) -> List(String) {
  case maybe_value {
    Some(value) -> [prefixed_line(field, int.to_string(value)), ..lines]
    None -> lines
  }
}

fn encode_comment_with_line_ending(
  text: String,
  line_ending: LineEnding,
) -> String {
  // The `Comment` opaque is sanitised at construction (#68), so by
  // the time the encoder sees `text` it cannot contain CR / LF / NUL.
  // Emit a single `:` line.
  let newline = line_ending_to_string(line_ending)
  comment_line(text) <> newline
}

fn comment_line(text: String) -> String {
  case text {
    "" -> ":"
    _ -> ": " <> text
  }
}

fn prefixed_line(field: String, value: String) -> String {
  case value {
    "" -> field <> ":"
    _ -> field <> ": " <> value
  }
}

fn line_ending_to_string(line_ending: LineEnding) -> String {
  case line_ending {
    Lf -> "\n"
    Crlf -> "\r\n"
  }
}

fn normalise_newlines(text: String) -> String {
  // Walk the bytes once and rewrite every CRLF / lone CR to LF in a
  // single pass. The two-pass `string.replace` shape this replaced
  // could leave a stray CR behind on the BEAM for inputs like
  // `"a\n\r\r\n"` — the first pass consumes the trailing `\r\n`,
  // and the lone `\r` survives the second pass because of how
  // `:binary.replace` handles the surrounding LF context. (#58)
  //
  // The walker only substitutes individual ASCII bytes, so a valid
  // UTF-8 input remains valid UTF-8 — `let assert` here is a
  // total-function declaration, not error swallowing.
  // nolint: assert_ok_pattern -- ASCII-only byte substitution preserves UTF-8 validity
  let assert Ok(s) =
    text
    |> bit_array.from_string
    |> walk_normalise_newlines(<<>>)
    |> bit_array.to_string
  s
}

fn walk_normalise_newlines(input: BitArray, acc: BitArray) -> BitArray {
  case input {
    <<>> -> acc
    <<13, 10, rest:bytes>> -> walk_normalise_newlines(rest, <<acc:bits, 10>>)
    <<13, rest:bytes>> -> walk_normalise_newlines(rest, <<acc:bits, 10>>)
    <<byte, rest:bytes>> -> walk_normalise_newlines(rest, <<acc:bits, byte>>)
    _ -> acc
  }
}
