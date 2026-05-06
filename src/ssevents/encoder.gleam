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
    event.Comment(text) -> encode_comment_with_line_ending(text, line_ending)
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

  let data_lines =
    event.data_of(ev)
    |> normalise_newlines
    |> string.split(on: "\n")
    |> list.map(fn(line) { prefixed_line("data", line) })

  list.append(prefix_lines, data_lines)
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
  let newline = line_ending_to_string(line_ending)

  // WHATWG SSE §9.2.6 has no notion of a multi-line comment, so a
  // `Comment(text)` whose `text` contained CR / LF used to fan out
  // to one `:` line per fragment; `decoder.decode` would then
  // surface each line as a separate `Comment`, breaking the
  // round-trip law `decode(encode(item)) == [item]`. Strip CR / LF
  // here so a `Comment` is always emitted as a single `:` line —
  // same silent-sanitisation posture `sanitize_field_value` takes
  // for `event:` and `id:` (#39). (#61)
  let sanitised = strip_line_breaks(text)
  comment_line(sanitised) <> newline
}

fn strip_line_breaks(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.filter(fn(cp) {
    let codepoint = string.utf_codepoint_to_int(cp)
    codepoint != 0x0D && codepoint != 0x0A
  })
  |> string.from_utf_codepoints
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
