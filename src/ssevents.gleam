//// Encode and decode Server-Sent Events, the `text/event-stream` format.
////
//// A server builds each `Event` with `new` or `named`, adds `id` and
//// `retry` when it needs them, and writes the stream with `encode` or
//// `encode_items`. A client reads a whole body with `decode`, or one
//// chunk at a time with `new_decoder`, `push` and `finish`.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// Events and comments --------------------------------------------------------

/// An event with its `event`, `data`, `id` and `retry` fields.
///
/// Build one with `new` or `named`, and read it with `name_of`, `data_of`,
/// `id_of` and `retry_of`.
///
pub opaque type Event {
  // `name` holds no CR or LF, `id` holds no CR, LF or NUL, `data` holds
  // no CR, and `retry` is not negative. That keeps every encoded field on
  // one line and makes `decode` return the event that was encoded.
  Event(
    name: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

/// The text of a comment line. Build one with `comment`.
///
pub opaque type Comment {
  // `text` holds no CR or LF, so it is written as one line.
  Comment(text: String)
}

/// What a stream holds, in the order it appears.
///
pub type Item {
  EventItem(Event)
  CommentItem(Comment)
  /// The `id` and `retry` of a block that has no `data` line. A browser
  /// does not dispatch such a block as an event, but it keeps the id to
  /// send in `Last-Event-ID` and waits `retry` milliseconds before it
  /// reconnects. `id: Some("")` clears the last event id.
  ReconnectItem(id: Option(String), retry: Option(Int))
}

/// Returns `"text/event-stream"`, the media type of an event stream
/// response.
///
pub fn content_type() -> String {
  "text/event-stream"
}

/// Creates an event without a name, which a browser `EventSource` hands to
/// its `message` listeners.
///
/// CR and CRLF in `data` become LF, so `data_of` returns what a client
/// will see.
///
/// ## Examples
///
/// ```gleam
/// ssevents.new("a\r\nb") |> ssevents.data_of
/// // -> "a\nb"
/// ```
///
pub fn new(data: String) -> Event {
  Event(name: None, data: clean_data(data), id: None, retry: None)
}

/// Creates an event whose `event` field is `name`, which a browser
/// `EventSource` hands to the listeners for that name.
///
/// Returns an error when `name` holds a CR or LF, which would end the
/// line on the wire. `data` is cleaned as in `new`, and an empty name
/// gives the same event as `new`.
///
/// ## Examples
///
/// ```gleam
/// ssevents.named("job.done", "42") |> result.map(ssevents.name_of)
/// // -> Ok(Some("job.done"))
/// ```
///
/// ```gleam
/// ssevents.named("job\ndata: forged", "42")
/// // -> Error(Nil)
/// ```
///
pub fn named(name: String, data: String) -> Result(Event, Nil) {
  use name <- result.map(single_line(name, []))
  Event(..new(data), name: name_field(name))
}

// A browser hands an event with an empty name to its `message` listeners,
// the same as one without a name.
fn name_field(name: String) -> Option(String) {
  case name {
    "" -> None
    _ -> Some(name)
  }
}

/// Sets the `id` field. A client sends the last id it saw back in the
/// `Last-Event-ID` header when it reconnects.
///
/// Returns an error when `id` holds a CR or LF, which would end the line
/// on the wire, or a NUL, which makes a browser ignore the field. An empty
/// `id` tells the client to forget the last one.
///
/// ## Examples
///
/// ```gleam
/// ssevents.new("x") |> ssevents.id("7") |> result.map(ssevents.id_of)
/// // -> Ok(Some("7"))
/// ```
///
pub fn id(event: Event, id: String) -> Result(Event, Nil) {
  use id <- result.map(single_line(id, [0]))
  Event(..event, id: Some(id))
}

/// Sets the `retry` field, the number of milliseconds a client waits
/// before it reconnects.
///
/// A value below 0 or above 86_400_000 (24 hours) removes the field
/// instead: the format has no negative numbers, and `decode` with
/// `default_limits` ignores larger values.
///
/// ## Examples
///
/// ```gleam
/// ssevents.new("x") |> ssevents.retry(5000) |> ssevents.retry_of
/// // -> Some(5000)
/// ```
///
/// ```gleam
/// ssevents.new("x") |> ssevents.retry(-1) |> ssevents.retry_of
/// // -> None
/// ```
///
pub fn retry(event: Event, milliseconds: Int) -> Event {
  Event(..event, retry: clean_retry(milliseconds))
}

/// Returns the `event` field, or `None` for an event made with `new`.
///
pub fn name_of(event: Event) -> Option(String) {
  event.name
}

/// Returns the `data` field. Lines are separated by LF.
///
pub fn data_of(event: Event) -> String {
  event.data
}

/// Returns the `id` field.
///
pub fn id_of(event: Event) -> Option(String) {
  event.id
}

/// Returns the `retry` field in milliseconds.
///
pub fn retry_of(event: Event) -> Option(Int) {
  event.retry
}

/// Creates a comment line. Clients ignore comments, so a server can send
/// one to keep an idle connection open.
///
/// Returns an error when `text` holds a CR or LF, because a comment is a
/// single line.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ping) = ssevents.comment("ping")
/// ssevents.encode_items([ping])
/// // -> ": ping\n"
/// ```
///
pub fn comment(text: String) -> Result(Item, Nil) {
  use text <- result.map(single_line(text, []))
  CommentItem(Comment(text:))
}

/// Returns the text of a comment.
///
pub fn comment_text(comment: Comment) -> String {
  comment.text
}

// Returns `value` if it holds no CR, LF or any of the `also` bytes. The
// bytes are checked because `string.contains` matches graphemes on
// Erlang, where CRLF is one.
fn single_line(value: String, also: List(Int)) -> Result(String, Nil) {
  use <- bool.guard(
    when: has_byte(<<value:utf8>>, [10, 13, ..also]),
    return: Error(Nil),
  )
  Ok(value)
}

fn has_byte(bytes: BitArray, wanted: List(Int)) -> Bool {
  case bytes {
    <<byte, rest:bytes>> ->
      case list.contains(wanted, byte) {
        True -> True
        False -> has_byte(rest, wanted)
      }
    _ -> False
  }
}

fn clean_retry(milliseconds: Int) -> Option(Int) {
  let max = default_limits.max_retry_value
  case milliseconds {
    _ if milliseconds < 0 || milliseconds > max -> None
    _ -> Some(milliseconds)
  }
}

// `string.replace` cannot tell the CR of a CRLF pair from a lone CR on
// both targets: it matches graphemes on Erlang and code units on
// JavaScript. `string.to_graphemes` gives `"\r\n"` as one grapheme on
// Erlang and as `"\r"`, `"\n"` where JavaScript has no `Intl.Segmenter`,
// so both shapes are matched here.
fn clean_data(value: String) -> String {
  clean_data_loop(string.to_graphemes(value), [])
}

fn clean_data_loop(graphemes: List(String), acc: List(String)) -> String {
  case graphemes {
    [] -> acc |> list.reverse |> string.concat
    ["\r", "\n", ..rest] | ["\r\n", ..rest] | ["\r", ..rest] ->
      clean_data_loop(rest, ["\n", ..acc])
    [grapheme, ..rest] -> clean_data_loop(rest, [grapheme, ..acc])
  }
}

// Encoding -------------------------------------------------------------------

/// Encodes one event, ending with the blank line that makes a client
/// dispatch it. Lines end with LF.
///
/// A data line longer than 8000 bytes is written as several `data` lines
/// of at most 2000 code points each, so that `decode` with
/// `default_limits` can read it. A client joins those lines with LF, so
/// the data it receives has an LF at each split. Data that has to arrive
/// unchanged needs lines of at most 8000 bytes. The `event` and `id` lines
/// are never split, so a name or id longer than about 8000 bytes gives a
/// stream that `decode` with `default_limits` rejects.
///
/// ## Examples
///
/// ```gleam
/// ssevents.new("a\nb") |> ssevents.retry(500) |> ssevents.encode
/// // -> "retry: 500\ndata: a\ndata: b\n\n"
/// ```
///
pub fn encode(event: Event) -> String {
  let data =
    event.data
    |> string.split(on: "\n")
    |> list.flat_map(split_long_line)
    |> list.map(field_line("data", _))
  block(event.name, event.id, event.retry, data)
}

// The `event`, `id` and `retry` lines, then `data`, then the blank line.
fn block(
  name: Option(String),
  id: Option(String),
  retry: Option(Int),
  data: List(String),
) -> String {
  [
    option.map(name, field_line("event", _)),
    option.map(id, field_line("id", _)),
    option.map(retry, fn(ms) { field_line("retry", int.to_string(ms)) }),
  ]
  |> option.values
  |> list.append(data)
  |> string.concat
  |> string.append("\n")
}

/// Encodes the items in order into one string.
///
/// A `ReconnectItem` is written as a block without `data`. Its `id` is
/// left out, without an error, if `id` would refuse it, and its `retry` if
/// `retry` would remove it, so a hand-built item cannot add lines to the
/// stream. An item with neither is written as nothing. Check a value from
/// a user with `id` first if losing it matters.
///
/// ## Examples
///
/// ```gleam
/// ssevents.encode_items([
///   ssevents.EventItem(ssevents.new("x")),
///   ssevents.ReconnectItem(id: None, retry: Some(5000)),
/// ])
/// // -> "data: x\n\nretry: 5000\n\n"
/// ```
///
pub fn encode_items(items: List(Item)) -> String {
  items
  |> list.map(fn(item) {
    case item {
      EventItem(event) -> encode(event)
      CommentItem(Comment(text: "")) -> ":\n"
      CommentItem(Comment(text:)) -> ": " <> text <> "\n"
      ReconnectItem(id:, retry:) ->
        case clean_reconnect(id, retry) {
          #(None, None) -> ""
          #(id, retry) -> block(None, id, retry, [])
        }
    }
  })
  |> string.concat
}

// A `ReconnectItem` can be built by hand, so its fields are checked as
// the builders check them, and a field they would refuse is dropped.
fn clean_reconnect(
  id: Option(String),
  retry: Option(Int),
) -> #(Option(String), Option(Int)) {
  #(
    option.then(id, fn(id) { option.from_result(single_line(id, [0])) }),
    option.then(retry, clean_retry),
  )
}

fn field_line(field: String, value: String) -> String {
  case value {
    "" -> field <> ":\n"
    _ -> field <> ": " <> value <> "\n"
  }
}

// 2000 code points take at most 8000 bytes in UTF-8, which leaves room for
// the `data: ` prefix under the default `max_line_bytes` of 8192.
const max_line_code_points = 2000

fn split_long_line(line: String) -> List(String) {
  case string.byte_size(line) <= max_line_code_points * 4 {
    True -> [line]
    False ->
      line
      |> string.to_utf_codepoints
      |> list.sized_chunk(into: max_line_code_points)
      |> list.map(string.from_utf_codepoints)
  }
}

// Decoding -------------------------------------------------------------------

/// Bounds on what the decoder accepts, so a peer cannot make it buffer
/// without limit. The values are not checked, and a value below 1 rejects
/// what it bounds: a `max_line_bytes` of 0 allows only blank lines and a
/// negative one not even those, a `max_event_bytes` or `max_data_lines`
/// of 0 rejects every field or `data` line, and a negative
/// `max_retry_value` ignores every `retry`. Start from `default_limits`
/// and change the fields you need:
///
/// ```gleam
/// ssevents.Limits(..ssevents.default_limits, max_event_bytes: 200_000)
/// ```
///
pub type Limits {
  Limits(
    /// The longest line in bytes, not counting its line ending.
    max_line_bytes: Int,
    /// The most bytes the field lines of one event can add up to. Comment
    /// lines do not count.
    max_event_bytes: Int,
    /// The most `data` lines one event can have.
    max_data_lines: Int,
    /// The largest `retry` value in milliseconds. A larger value is
    /// ignored and the event is still returned.
    max_retry_value: Int,
  )
}

/// 8192 bytes per line, 65_536 bytes per event, 1024 `data` lines per
/// event, and a `retry` of at most 86_400_000 milliseconds (24 hours).
///
pub const default_limits =
  Limits(
    max_line_bytes: 8192,
    max_event_bytes: 65_536,
    max_data_lines: 1024,
    max_retry_value: 86_400_000,
  )

/// Why a stream could not be decoded.
///
pub type SseError {
  /// A line is longer than `max_line_bytes`.
  LineTooLong(limit: Int)
  /// An event is larger than `max_event_bytes`.
  EventTooLarge(limit: Int)
  /// An event has more `data` lines than `max_data_lines`.
  TooManyDataLines(limit: Int)
}

/// Describes an error in English, for logs.
///
pub fn error_to_string(error: SseError) -> String {
  case error {
    LineTooLong(limit:) ->
      "line exceeds configured byte limit " <> int.to_string(limit)
    EventTooLarge(limit:) ->
      "event exceeds configured byte limit " <> int.to_string(limit)
    TooManyDataLines(limit:) ->
      "event exceeds configured data-line limit " <> int.to_string(limit)
  }
}

/// Decodes a whole stream into its items, as the WHATWG HTML standard
/// reads an event stream.
///
/// Lines can end with LF, CRLF or CR, a byte order mark at the start is
/// skipped, and bytes that are not UTF-8 become U+FFFD. Unknown fields are
/// ignored, as are an `id` that contains NUL and a `retry` that is not all
/// digits or is above `max_retry_value`. A block with `data` gives an
/// `EventItem`, and a block without it gives a `ReconnectItem` if it has an
/// `id` or a `retry`. An event at the end of the input without its closing
/// blank line is dropped, as a browser drops it, but its `retry` is kept.
/// The first error ends decoding.
///
/// ## Examples
///
/// ```gleam
/// ssevents.decode(<<"data: 1\n\nretry: 50\n\n":utf8>>, ssevents.default_limits)
/// // -> Ok([
/// //   ssevents.EventItem(ssevents.new("1")),
/// //   ssevents.ReconnectItem(id: None, retry: Some(50)),
/// // ])
/// ```
///
/// ```gleam
/// let limits = ssevents.Limits(..ssevents.default_limits, max_line_bytes: 4)
/// ssevents.decode(<<"data: hello\n\n":utf8>>, limits)
/// // -> Error(ssevents.LineTooLong(limit: 4))
/// ```
///
pub fn decode(input: BitArray, limits: Limits) -> Result(List(Item), SseError) {
  use #(state, items) <- result.map(push(new_decoder(limits), input))
  list.append(items, finish(state))
}

/// The state of a decoder that reads a stream one chunk at a time.
///
pub opaque type DecodeState {
  DecodeState(
    limits: Limits,
    // Bytes of a line that has not ended yet.
    buffer: BitArray,
    // How many bytes at the start of `buffer` are known to hold no line
    // ending, so a line that arrives in many chunks is scanned once.
    scanned: Int,
    // False until the first bytes show whether the stream starts with a
    // byte order mark.
    bom_checked: Bool,
    // True when the last line ended with a CR at the end of a chunk, so an
    // LF at the start of the next chunk is the rest of a CRLF.
    skip_lf: Bool,
    name: Option(String),
    // The `data` lines of the current event, last line first.
    data_lines: List(String),
    data_line_count: Int,
    id: Option(String),
    retry: Option(Int),
    event_bytes: Int,
  )
}

/// Creates a decoder for a stream that arrives in chunks, such as the body
/// of an HTTP response. Give each chunk to `push` and call `finish` when
/// the stream ends.
///
pub fn new_decoder(limits: Limits) -> DecodeState {
  DecodeState(
    limits:,
    buffer: <<>>,
    scanned: 0,
    bom_checked: False,
    skip_lf: False,
    name: None,
    data_lines: [],
    data_line_count: 0,
    id: None,
    retry: None,
    event_bytes: 0,
  )
}

/// Reads the next chunk and returns the items it completes.
///
/// A chunk can end anywhere, even inside a character. The bytes of an
/// unfinished line wait for the next chunk. Returns the same items and
/// errors as `decode` would for the whole stream, however it is split.
///
/// ## Examples
///
/// ```gleam
/// let decoder = ssevents.new_decoder(ssevents.default_limits)
/// let assert Ok(#(decoder, [])) = ssevents.push(decoder, <<"data: he":utf8>>)
/// ssevents.push(decoder, <<"llo\n\n":utf8>>)
/// // -> Ok(#(_, [ssevents.EventItem(ssevents.new("hello"))]))
/// ```
///
pub fn push(
  state: DecodeState,
  chunk: BitArray,
) -> Result(#(DecodeState, List(Item)), SseError) {
  DecodeState(..state, buffer: bit_array.append(state.buffer, chunk))
  |> skip_byte_order_mark
  |> skip_lf_after_cr
  |> read_lines([])
}

/// Ends the stream. The event that has not seen its closing blank line is
/// dropped, as is a last line without a line ending, and a `retry` already
/// read for that event is returned as a `ReconnectItem`.
///
pub fn finish(state: DecodeState) -> List(Item) {
  case state.retry {
    Some(_) -> [ReconnectItem(id: None, retry: state.retry)]
    None -> []
  }
}

fn skip_byte_order_mark(state: DecodeState) -> DecodeState {
  case state.bom_checked, state.buffer {
    True, _ -> state
    False, <<0xEF, 0xBB, 0xBF, rest:bytes>> ->
      DecodeState(..state, buffer: rest, scanned: 0, bom_checked: True)
    // The mark may be split across chunks.
    False, <<0xEF, 0xBB>> | False, <<0xEF>> | False, <<>> -> state
    False, _ -> DecodeState(..state, bom_checked: True)
  }
}

fn skip_lf_after_cr(state: DecodeState) -> DecodeState {
  case state.skip_lf, state.buffer {
    False, _ | True, <<>> -> state
    True, <<10, rest:bytes>> ->
      DecodeState(..state, buffer: rest, skip_lf: False)
    True, _ -> DecodeState(..state, skip_lf: False)
  }
}

fn read_lines(
  state: DecodeState,
  items: List(Item),
) -> Result(#(DecodeState, List(Item)), SseError) {
  let max = state.limits.max_line_bytes
  let size = bit_array.byte_size(state.buffer)
  let unscanned =
    bit_array.slice(state.buffer, state.scanned, size - state.scanned)
    |> result.unwrap(<<>>)
  case line_end(unscanned, state.scanned) {
    Ok(#(length, ending)) ->
      case length > max {
        True -> Error(LineTooLong(limit: max))
        False -> {
          let #(line, rest) = split_bytes(state.buffer, length, ending)
          // A CR that ends the buffer ends the line now, so the event is
          // not held back until the next chunk shows what follows it.
          let skip_lf =
            ending == 1
            && rest == <<>>
            && bit_array.slice(state.buffer, length, 1) == Ok(<<13>>)
          use #(state, item) <- result.try(read_line(
            DecodeState(..state, buffer: rest, scanned: 0, skip_lf:),
            line,
          ))
          case item {
            Some(item) -> read_lines(state, [item, ..items])
            None -> read_lines(state, items)
          }
        }
      }
    // Until the byte order mark is checked, the buffer holds at most the
    // start of the mark, which is not part of a line.
    Error(Nil) ->
      case size > max && state.bom_checked {
        True -> Error(LineTooLong(limit: max))
        False -> Ok(#(DecodeState(..state, scanned: size), list.reverse(items)))
      }
  }
}

// Returns the length of the first line in `bytes`, starting the count at
// `length`, and the length of its line ending.
fn line_end(bytes: BitArray, length: Int) -> Result(#(Int, Int), Nil) {
  case bytes {
    <<13, 10, _:bytes>> -> Ok(#(length, 2))
    <<13, _:bytes>> | <<10, _:bytes>> -> Ok(#(length, 1))
    <<_, rest:bytes>> -> line_end(rest, length + 1)
    _ -> Error(Nil)
  }
}

fn split_bytes(
  bytes: BitArray,
  length: Int,
  skip: Int,
) -> #(BitArray, BitArray) {
  let size = bit_array.byte_size(bytes)
  let head = bit_array.slice(bytes, 0, length) |> result.unwrap(<<>>)
  let tail =
    bit_array.slice(bytes, length + skip, size - length - skip)
    |> result.unwrap(<<>>)
  #(head, tail)
}

fn read_line(
  state: DecodeState,
  line: BitArray,
) -> Result(#(DecodeState, Option(Item)), SseError) {
  case line {
    <<>> -> Ok(dispatch(state))
    <<":":utf8, text:bytes>> -> {
      let text = to_text(drop_leading_space(text))
      Ok(#(state, Some(CommentItem(Comment(text:)))))
    }
    _ -> {
      let #(field, value) = split_field(line)
      let field = to_text(field)
      let value = to_text(value)
      let event_bytes = state.event_bytes + bit_array.byte_size(line)
      case event_bytes > state.limits.max_event_bytes {
        True -> Error(EventTooLarge(limit: state.limits.max_event_bytes))
        False ->
          apply_field(DecodeState(..state, event_bytes:), field, value)
          |> result.map(fn(state) { #(state, None) })
      }
    }
  }
}

// Splits a field line at its first colon and drops one space after it. A
// line without a colon is a field name with an empty value.
fn split_field(line: BitArray) -> #(BitArray, BitArray) {
  case colon_index(line, 0) {
    Ok(index) -> {
      let #(field, value) = split_bytes(line, index, 1)
      #(field, drop_leading_space(value))
    }
    Error(Nil) -> #(line, <<>>)
  }
}

fn colon_index(bytes: BitArray, index: Int) -> Result(Int, Nil) {
  case bytes {
    <<":":utf8, _:bytes>> -> Ok(index)
    <<_, rest:bytes>> -> colon_index(rest, index + 1)
    _ -> Error(Nil)
  }
}

fn drop_leading_space(bytes: BitArray) -> BitArray {
  case bytes {
    <<" ":utf8, rest:bytes>> -> rest
    _ -> bytes
  }
}

// Reads UTF-8 as the WHATWG UTF-8 decoder does, with each maximal invalid
// sequence read as one U+FFFD. `bit_array.to_string` drops a byte order
// mark at the start of its input on JavaScript, where it uses
// `TextDecoder`, and keeps it on Erlang, so the mark is read here and both
// targets return the same text.
fn to_text(bytes: BitArray) -> String {
  case valid_text(bytes, "") {
    Ok(text) -> text
    Error(Nil) -> replace_invalid(bytes, [])
  }
}

fn valid_text(bytes: BitArray, marks: String) -> Result(String, Nil) {
  case bytes {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> valid_text(rest, marks <> "\u{FEFF}")
    _ -> bit_array.to_string(bytes) |> result.map(string.append(marks, _))
  }
}

// `first_invalid` accepts exactly what `bit_array.to_string` accepts, so
// the U+FFFD fallbacks below are never taken.
fn replace_invalid(bytes: BitArray, acc: List(String)) -> String {
  case first_invalid(bytes, 0) {
    Error(Nil) -> {
      let text = valid_text(bytes, "") |> result.unwrap("\u{FFFD}")
      [text, ..acc] |> list.reverse |> string.concat
    }
    Ok(#(index, length)) -> {
      let #(valid, rest) = split_bytes(bytes, index, length)
      let text = valid_text(valid, "") |> result.unwrap("\u{FFFD}")
      replace_invalid(rest, ["\u{FFFD}", text, ..acc])
    }
  }
}

// Returns where the first invalid sequence starts, counting from `index`,
// and how many bytes it takes.
fn first_invalid(bytes: BitArray, index: Int) -> Result(#(Int, Int), Nil) {
  case bytes {
    <<byte, rest:bytes>> if byte < 0x80 -> first_invalid(rest, index + 1)
    <<byte, rest:bytes>> -> {
      let #(needed, lower, upper) = utf8_lead(byte)
      let seen = continuation_bytes(rest, needed, lower, upper, 0)
      case needed > 0 && seen == needed {
        True -> first_invalid(drop_bytes(rest, needed), index + 1 + needed)
        False -> Ok(#(index, 1 + seen))
      }
    }
    _ -> Error(Nil)
  }
}

// How many continuation bytes a lead byte needs, and the range the first
// of them must be in. A byte that cannot start a sequence needs none.
fn utf8_lead(byte: Int) -> #(Int, Int, Int) {
  case byte {
    0xE0 -> #(2, 0xA0, 0xBF)
    0xED -> #(2, 0x80, 0x9F)
    0xF0 -> #(3, 0x90, 0xBF)
    0xF4 -> #(3, 0x80, 0x8F)
    _ if byte >= 0xC2 && byte <= 0xDF -> #(1, 0x80, 0xBF)
    _ if byte >= 0xE1 && byte <= 0xEF -> #(2, 0x80, 0xBF)
    _ if byte >= 0xF1 && byte <= 0xF3 -> #(3, 0x80, 0xBF)
    _ -> #(0, 0, 0)
  }
}

fn continuation_bytes(
  bytes: BitArray,
  needed: Int,
  lower: Int,
  upper: Int,
  seen: Int,
) -> Int {
  case bytes {
    <<byte, rest:bytes>> if seen < needed && byte >= lower && byte <= upper ->
      continuation_bytes(rest, needed, 0x80, 0xBF, seen + 1)
    _ -> seen
  }
}

fn drop_bytes(bytes: BitArray, count: Int) -> BitArray {
  case count, bytes {
    0, _ -> bytes
    _, <<_, rest:bytes>> -> drop_bytes(rest, count - 1)
    _, _ -> bytes
  }
}

fn apply_field(
  state: DecodeState,
  field: String,
  value: String,
) -> Result(DecodeState, SseError) {
  case field {
    "data" ->
      case state.data_line_count < state.limits.max_data_lines {
        True ->
          Ok(
            DecodeState(
              ..state,
              data_lines: [value, ..state.data_lines],
              data_line_count: state.data_line_count + 1,
            ),
          )
        False -> Error(TooManyDataLines(limit: state.limits.max_data_lines))
      }
    "event" -> Ok(DecodeState(..state, name: Some(value)))
    // An id that contains NUL is ignored.
    "id" ->
      case has_byte(<<value:utf8>>, [0]) {
        True -> Ok(state)
        False -> Ok(DecodeState(..state, id: Some(value)))
      }
    // A retry that is not all ASCII digits is ignored.
    "retry" ->
      case all_digits(<<value:utf8>>) && value != "" {
        True ->
          case int.parse(value) {
            Ok(ms) if ms <= state.limits.max_retry_value ->
              Ok(DecodeState(..state, retry: Some(ms)))
            _ -> Ok(state)
          }
        False -> Ok(state)
      }
    _ -> Ok(state)
  }
}

fn all_digits(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<digit, rest:bytes>> if digit >= 0x30 && digit <= 0x39 -> all_digits(rest)
    _ -> False
  }
}

// Ends the current block at a blank line. A browser dispatches an event
// only for a block with a `data` field, but it takes the id of any block.
fn dispatch(state: DecodeState) -> #(DecodeState, Option(Item)) {
  let item = case state.data_line_count, state.id, state.retry {
    0, None, None -> None
    0, id, retry -> Some(ReconnectItem(id:, retry:))
    _, id, retry ->
      Some(
        EventItem(Event(
          name: option.then(state.name, name_field),
          data: state.data_lines |> list.reverse |> string.join(with: "\n"),
          id:,
          retry:,
        )),
      )
  }
  let next =
    DecodeState(
      ..new_decoder(state.limits),
      buffer: state.buffer,
      bom_checked: state.bom_checked,
      skip_lf: state.skip_lf,
    )
  #(next, item)
}

// Reconnecting ---------------------------------------------------------------

/// What a client remembers between connections: the last `id` it saw,
/// which it sends in the `Last-Event-ID` header, and the last `retry`.
///
/// Start from `ReconnectState(last_event_id: None, retry: None)` and give
/// each item to `update_reconnect`.
///
pub type ReconnectState {
  ReconnectState(last_event_id: Option(String), retry: Option(Int))
}

/// Keeps the `id` and `retry` of an `EventItem` or a `ReconnectItem`, if
/// it has them. An empty `id` sets `last_event_id` back to `None`, as a
/// browser then sends no `Last-Event-ID`. Comments leave the state as it
/// is. A `ReconnectItem` field that `id` or `retry` would refuse is
/// ignored, so the state never holds an id that cannot be sent as a
/// header.
///
pub fn update_reconnect(state: ReconnectState, item: Item) -> ReconnectState {
  let #(id, retry) = case item {
    CommentItem(_) -> #(None, None)
    EventItem(Event(id:, retry:, ..)) -> #(id, retry)
    ReconnectItem(id:, retry:) -> clean_reconnect(id, retry)
  }
  ReconnectState(
    last_event_id: case id {
      // An empty id resets it, and no header is sent.
      Some("") -> None
      Some(id) -> Some(id)
      None -> state.last_event_id
    },
    retry: option.or(retry, state.retry),
  )
}
