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
  // `name` and `id` hold no CR, LF or NUL, `data` holds no CR or NUL, and
  // `retry` is not negative. That keeps every encoded field on one line
  // and makes `decode` return the event that was encoded.
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
  // `text` holds no CR, LF or NUL, so it is written as one line.
  Comment(text: String)
}

/// An event or a comment, in the order they appear in a stream.
///
pub type Item {
  EventItem(Event)
  CommentItem(Comment)
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
/// CR and CRLF in `data` become LF and NUL is removed, so `data_of` returns
/// what a client will see.
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
/// CR, LF and NUL are removed from `name`, and `data` is cleaned as in
/// `new`.
///
/// ## Examples
///
/// ```gleam
/// ssevents.named("job.done", "42") |> ssevents.name_of
/// // -> Some("job.done")
/// ```
///
pub fn named(name: String, data: String) -> Event {
  Event(..new(data), name: Some(clean_field(name)))
}

/// Sets the `id` field. A client sends the last id it saw back in the
/// `Last-Event-ID` header when it reconnects.
///
/// CR, LF and NUL are removed from `id`.
///
pub fn id(event: Event, id: String) -> Event {
  Event(..event, id: Some(clean_field(id)))
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
/// CR, LF and NUL are removed from `text`, because a comment is a single
/// line.
///
/// ## Examples
///
/// ```gleam
/// ssevents.encode_items([ssevents.comment("ping")])
/// // -> ": ping\n"
/// ```
///
pub fn comment(text: String) -> Item {
  CommentItem(Comment(text: clean_field(text)))
}

/// Returns the text of a comment.
///
pub fn comment_text(comment: Comment) -> String {
  comment.text
}

fn clean_field(value: String) -> String {
  value
  |> string.replace(each: "\r\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\u{0000}", with: "")
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
    ["\u{0000}", ..rest] -> clean_data_loop(rest, acc)
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
/// unchanged needs lines of at most 8000 bytes.
///
/// ## Examples
///
/// ```gleam
/// ssevents.named("update", "a\nb") |> ssevents.id("7") |> ssevents.encode
/// // -> "event: update\nid: 7\ndata: a\ndata: b\n\n"
/// ```
///
pub fn encode(event: Event) -> String {
  let fields =
    [
      option.map(event.name, field_line("event", _)),
      option.map(event.id, field_line("id", _)),
      option.map(event.retry, fn(ms) { field_line("retry", int.to_string(ms)) }),
    ]
    |> option.values
  let data =
    event.data
    |> string.split(on: "\n")
    |> list.flat_map(split_long_line)
    |> list.map(field_line("data", _))
  string.concat(list.append(fields, data)) <> "\n"
}

/// Encodes events and comments in order into one string.
///
/// ## Examples
///
/// ```gleam
/// ssevents.encode_items([
///   ssevents.comment("hello"),
///   ssevents.EventItem(ssevents.new("x")),
/// ])
/// // -> ": hello\ndata: x\n\n"
/// ```
///
pub fn encode_items(items: List(Item)) -> String {
  items
  |> list.map(fn(item) {
    case item {
      EventItem(event) -> encode(event)
      CommentItem(Comment(text: "")) -> ":\n"
      CommentItem(Comment(text:)) -> ": " <> text <> "\n"
    }
  })
  |> string.concat
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
/// without limit. Start from `default_limits` and change the fields you
/// need:
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
  /// The input is not valid UTF-8.
  InvalidUtf8
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
    InvalidUtf8 -> "invalid UTF-8 in SSE input"
    LineTooLong(limit:) ->
      "line exceeds configured byte limit " <> int.to_string(limit)
    EventTooLarge(limit:) ->
      "event exceeds configured byte limit " <> int.to_string(limit)
    TooManyDataLines(limit:) ->
      "event exceeds configured data-line limit " <> int.to_string(limit)
  }
}

/// Decodes a whole stream into its events and comments.
///
/// Lines can end with LF, CRLF or CR, and a byte order mark at the start
/// is skipped. Unknown fields are ignored, as are an `id` that contains
/// NUL and a `retry` that is not all digits or is above `max_retry_value`.
/// A block of lines with no `data` field is not returned, as a browser
/// does not dispatch it. An event at the end of the input without the
/// closing blank line is still returned. The first error ends decoding.
///
/// ## Examples
///
/// ```gleam
/// ssevents.decode(<<"event: ping\ndata: 1\n\n":utf8>>, ssevents.default_limits)
/// // -> Ok([ssevents.EventItem(ssevents.named("ping", "1"))])
/// ```
///
/// ```gleam
/// let limits = ssevents.Limits(..ssevents.default_limits, max_line_bytes: 4)
/// ssevents.decode(<<"data: hello\n\n":utf8>>, limits)
/// // -> Error(ssevents.LineTooLong(limit: 4))
/// ```
///
pub fn decode(input: BitArray, limits: Limits) -> Result(List(Item), SseError) {
  use #(state, items) <- result.try(push(new_decoder(limits), input))
  use rest <- result.map(finish(state))
  list.append(items, rest)
}

/// The state of a decoder that reads a stream one chunk at a time.
///
pub opaque type DecodeState {
  DecodeState(
    limits: Limits,
    // Bytes of a line that has not ended yet.
    buffer: BitArray,
    // False until the first bytes show whether the stream starts with a
    // byte order mark.
    bom_checked: Bool,
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
    bom_checked: False,
    name: None,
    data_lines: [],
    data_line_count: 0,
    id: None,
    retry: None,
    event_bytes: 0,
  )
}

/// Reads the next chunk and returns the events and comments it completes.
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
  |> read_lines([])
}

/// Ends the stream and returns what is left: the last line if it had no
/// line ending, and the event it belongs to.
///
pub fn finish(state: DecodeState) -> Result(List(Item), SseError) {
  case state.buffer {
    <<>> -> Ok(option.values([dispatch(state).1]))
    buffer -> {
      // No byte can follow a CR now, so it ends the line.
      let line = drop_trailing_cr(buffer)
      use #(state, item) <- result.map(read_line(
        DecodeState(..state, buffer: <<>>),
        line,
      ))
      option.values([item, dispatch(state).1])
    }
  }
}

fn skip_byte_order_mark(state: DecodeState) -> DecodeState {
  case state.bom_checked, state.buffer {
    True, _ -> state
    False, <<0xEF, 0xBB, 0xBF, rest:bytes>> ->
      DecodeState(..state, buffer: rest, bom_checked: True)
    // The mark may be split across chunks.
    False, <<0xEF, 0xBB>> | False, <<0xEF>> | False, <<>> -> state
    False, _ -> DecodeState(..state, bom_checked: True)
  }
}

fn read_lines(
  state: DecodeState,
  items: List(Item),
) -> Result(#(DecodeState, List(Item)), SseError) {
  let max = state.limits.max_line_bytes
  case line_end(state.buffer, 0) {
    Ok(#(length, ending)) ->
      case length > max {
        True -> Error(LineTooLong(limit: max))
        False -> {
          let #(line, rest) = split_bytes(state.buffer, length, ending)
          use #(state, item) <- result.try(read_line(
            DecodeState(..state, buffer: rest),
            line,
          ))
          case item {
            Some(item) -> read_lines(state, [item, ..items])
            None -> read_lines(state, items)
          }
        }
      }
    // A CR at the end of the buffer may be the start of a CRLF. It ends the
    // line either way, so it does not count towards the line's length.
    Error(Nil) ->
      case bit_array.byte_size(drop_trailing_cr(state.buffer)) > max {
        True -> Error(LineTooLong(limit: max))
        False -> Ok(#(state, list.reverse(items)))
      }
  }
}

// Returns the length of the first line in `bytes`, starting the count at
// `length`, and the length of its line ending.
fn line_end(bytes: BitArray, length: Int) -> Result(#(Int, Int), Nil) {
  case bytes {
    <<13, 10, _:bytes>> -> Ok(#(length, 2))
    <<13>> -> Error(Nil)
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

fn drop_trailing_cr(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  case bit_array.slice(bytes, size - 1, 1) {
    Ok(<<13>>) -> bit_array.slice(bytes, 0, size - 1) |> result.unwrap(bytes)
    _ -> bytes
  }
}

fn read_line(
  state: DecodeState,
  line: BitArray,
) -> Result(#(DecodeState, Option(Item)), SseError) {
  case line {
    <<>> -> Ok(dispatch(state))
    <<":":utf8, text:bytes>> -> {
      use text <- result.map(to_text(drop_leading_space(text)))
      #(state, Some(CommentItem(Comment(text: clean_field(text)))))
    }
    _ -> {
      let #(field, value) = split_field(line)
      use field <- result.try(to_text(field))
      use value <- result.try(to_text(value))
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

// `bit_array.to_string` drops a byte order mark at the start of its input
// on JavaScript, where it uses `TextDecoder`, and keeps it on Erlang. The
// mark is read here so both targets return the same text.
fn to_text(bytes: BitArray) -> Result(String, SseError) {
  case bytes {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> ->
      to_text(rest) |> result.map(fn(text) { "\u{FEFF}" <> text })
    _ -> bit_array.to_string(bytes) |> result.replace_error(InvalidUtf8)
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
      case string.contains(value, "\u{0000}") {
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

// Ends the current event at a blank line. Only an event with a `data`
// field is returned, as a browser does not dispatch one without it.
fn dispatch(state: DecodeState) -> #(DecodeState, Option(Item)) {
  let item = case state.data_line_count {
    0 -> None
    _ ->
      Some(
        EventItem(Event(
          name: option.map(state.name, clean_field),
          data: state.data_lines
            |> list.reverse
            |> string.join(with: "\n")
            |> remove_nul,
          id: state.id,
          retry: state.retry,
        )),
      )
  }
  let next =
    DecodeState(
      ..new_decoder(state.limits),
      buffer: state.buffer,
      bom_checked: state.bom_checked,
    )
  #(next, item)
}

// A line from the wire holds no CR or LF, so only NUL is left to remove.
fn remove_nul(data: String) -> String {
  use <- bool.guard(when: !string.contains(data, "\u{0000}"), return: data)
  clean_data(data)
}

// Reconnecting ---------------------------------------------------------------

/// What a client remembers between connections: the last `id` it saw,
/// which it sends in the `Last-Event-ID` header, and the last `retry`.
///
/// Start from `ReconnectState(last_event_id: None, retry: None)` and give
/// each item to `update_reconnect`. `decode` does not return a block
/// without a `data` field, so an `id` or `retry` sent on its own does not
/// reach this state.
///
pub type ReconnectState {
  ReconnectState(last_event_id: Option(String), retry: Option(Int))
}

/// Keeps the `id` and `retry` of an event, if it has them. Comments leave
/// the state as it is.
///
pub fn update_reconnect(state: ReconnectState, item: Item) -> ReconnectState {
  case item {
    CommentItem(_) -> state
    EventItem(event) ->
      ReconnectState(
        last_event_id: option.or(event.id, state.last_event_id),
        retry: option.or(event.retry, state.retry),
      )
  }
}
