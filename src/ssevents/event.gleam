//// Event and item domain values.
////
//// `Event` is opaque so the package can evolve its representation
//// without a breaking change. Construct via `new`, `from_parts`, and
//// the builder helpers. `Item` stays transparent because callers and
//// helper modules frequently pattern match on whether a stream element
//// is an event or a comment.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import ssevents/limit

pub opaque type Event {
  Event(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

pub type Item {
  EventItem(Event)
  Comment(String)
}

pub fn new(data: String) -> Event {
  Event(event: None, data: sanitize_data_value(data), id: None, retry: None)
}

pub fn from_parts(
  event_name event_name: Option(String),
  data data: String,
  id id: Option(String),
  retry retry: Option(Int),
) -> Event {
  Event(
    event: option_sanitize(event_name),
    data: sanitize_data_value(data),
    id: option_sanitize(id),
    retry: sanitize_retry(retry),
  )
}

pub fn message(data: String) -> Event {
  new(data)
}

pub fn named(name: String, data: String) -> Event {
  new(data) |> event(name)
}

pub fn event(event: Event, name: String) -> Event {
  Event(
    event: Some(sanitize_field_value(name)),
    data: event.data,
    id: event.id,
    retry: event.retry,
  )
}

pub fn id(event: Event, id: String) -> Event {
  Event(
    event: event.event,
    data: event.data,
    id: Some(sanitize_field_value(id)),
    retry: event.retry,
  )
}

/// Strip CR (U+000D), LF (U+000A), and NUL (U+0000) from `value`.
///
/// CR / LF inside an `event` or `id` value cannot survive the SSE wire
/// format — both are line terminators per WHATWG SSE §9.2.5, so a
/// literal CR / LF inside the value would split the field across two
/// lines on encode and the decoder would parse the post-LF tail as an
/// unrelated unknown field. NUL inside `id` is ignored by the decoder
/// per §9.2.6, breaking round-trip.
///
/// Stripping silently at construction time is the same posture
/// `multipartkit/form.add_field` takes for the analogous header-injection
/// risk: it keeps `from_parts`, `event/2`, and `id/2` infallible while
/// guaranteeing that `decode(encode(x))` round-trips for any caller-built
/// `Event`.
fn sanitize_field_value(value: String) -> String {
  value
  |> string.replace(each: "\r\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\u{0000}", with: "")
}

fn option_sanitize(opt: Option(String)) -> Option(String) {
  case opt {
    None -> None
    Some(value) -> Some(sanitize_field_value(value))
  }
}

pub fn retry(event: Event, milliseconds: Int) -> Event {
  Event(
    event: event.event,
    data: event.data,
    id: event.id,
    retry: sanitize_retry(Some(milliseconds)),
  )
}

/// Drop retry values that the SSE wire format / decoder will not
/// round-trip back to `Some(n)` under the default `Limits`.
///
/// WHATWG SSE §9.2.6 only recognises retry values whose textual form
/// is ASCII digits, so a negative value would be silently dropped on
/// decode. Values above `limit.default_max_retry_value` (24 hours in
/// milliseconds) hard-fail the default decoder. Coercing both to
/// `None` here matches the silent-sanitisation posture
/// `sanitize_field_value` takes for `event:` and `id:`, so
/// `decode(encode(event))` returns the same event for any caller-built
/// `Event`. (#60)
fn sanitize_retry(retry: Option(Int)) -> Option(Int) {
  case retry {
    None -> None
    Some(ms) ->
      case ms < 0 || ms > limit.default_max_retry_value {
        True -> None
        False -> Some(ms)
      }
  }
}

pub fn data(event: Event, data: String) -> Event {
  Event(
    event: event.event,
    data: sanitize_data_value(data),
    id: event.id,
    retry: event.retry,
  )
}

/// Strip CR (U+000D) and NUL (U+0000) from a `data` value, and
/// convert standalone CRLF graphemes to LF.
///
/// WHATWG SSE §9.2.6 normalises CR / CRLF / LF to LF on the wire side
/// and silently drops NUL, so neither sequence can survive
/// `decode(encode(x))` verbatim inside `data`. Strip / normalise both
/// at construction so the in-memory representation already matches
/// what the wire would carry. LF is preserved — `data` may
/// legitimately contain logical newlines, and the encoder splits on
/// LF to emit multi-line `data:` blocks; the decoder rejoins those
/// lines with LF, so `\n` round-trips cleanly.
///
/// The implementation maps over Unicode graphemes (`\r\n` is a single
/// grapheme per UAX #29). A `string.replace`-based pass cannot strip
/// the `\r` half of a CRLF pair on the JavaScript target because the
/// CRLF grapheme is opaque to substring search.
fn sanitize_data_value(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.flat_map(map_data_grapheme)
  |> string.join(with: "")
}

fn map_data_grapheme(grapheme: String) -> List(String) {
  case grapheme {
    "\r" -> []
    "\u{0000}" -> []
    "\r\n" -> ["\n"]
    other -> [other]
  }
}

pub fn name_of(event: Event) -> Option(String) {
  event.event
}

pub fn data_of(event: Event) -> String {
  event.data
}

pub fn id_of(event: Event) -> Option(String) {
  event.id
}

pub fn retry_of(event: Event) -> Option(Int) {
  event.retry
}

pub fn event_item(event: Event) -> Item {
  EventItem(event)
}
