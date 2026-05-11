//// Event and item domain values.
////
//// `Event` and `Comment` are opaque so the package can evolve their
//// representation without a breaking change. Construct via `new`,
//// `from_parts`, and the builder helpers (for `Event`) or `comment`
//// (for `Comment`). `Item` stays transparent so callers and helper
//// modules can pattern match on whether a stream element is an event
//// or a comment.

import gleam/int
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

/// A `:`-prefixed comment line in an SSE stream.
///
/// Opaque — construct with `comment/1` and inspect with
/// `comment_text_of/1`. Comment text is sanitised at construction
/// (CR / LF / NUL stripped) so `decode(encode([CommentItem(c)]))`
/// returns the same `Comment` value: WHATWG SSE §9.2.6 has no
/// notion of a multi-line comment, so any embedded line break would
/// fan out to multiple comments on the wire and break the
/// round-trip law.
pub opaque type Comment {
  Comment(text: String)
}

pub type Item {
  EventItem(Event)
  CommentItem(Comment)
}

/// Reasons the strict event-builder variants reject input.
///
/// The non-strict `event` / `id` / `named` / `comment` constructors
/// silently strip CR / LF / NUL bytes from the values that flow into
/// SSE field lines (so `named("\n", _)` produces an event with
/// `name = ""`, and `id(_, "ab\u{0000}cd")` produces an event with
/// `id = "abcd"` — a *different valid id*). The silent strip is
/// data loss the caller cannot observe — a naive equality check on
/// the recovered name silently matches the wrong subscription
/// channel. The `*_checked` variants surface this as a typed error
/// so callers can render "name `foo\\nbar` contains forbidden
/// control bytes" rather than producing the wrong wire silently.
/// (#81)
pub type EventError {
  /// `event_checked` saw CR / LF / NUL bytes in the event name.
  /// Carries the original (un-sanitized) value.
  NameContainsControlBytes(value: String)
  /// `id_checked` saw CR / LF / NUL bytes in the event id.
  /// Carries the original (un-sanitized) value.
  IdContainsControlBytes(value: String)
  /// `comment_checked` saw CR / LF / NUL bytes in the comment text.
  /// Carries the original (un-sanitized) value.
  CommentContainsControlBytes(value: String)
}

/// Build a `Comment` from a text payload. CR (U+000D), LF (U+000A),
/// and NUL (U+0000) are stripped at construction so the result
/// round-trips through `encode → decode` without fanning out into
/// multiple comments. Matches the `sanitize_field_value` posture
/// already used for `event_name` and `id`.
///
/// The silent strip is data loss the caller cannot observe. Reach
/// for `comment_checked/1` instead when comment text comes from
/// user-typed or upstream input and a typed error is preferable to
/// a silently-truncated comment. (#81)
pub fn comment(text: String) -> Comment {
  Comment(text: sanitize_field_value(text))
}

/// Extract the sanitised comment text.
pub fn comment_text_of(c: Comment) -> String {
  c.text
}

/// Wrap a `Comment` as a stream item. Convenience for the common
/// `CommentItem(comment(text))` two-step.
pub fn comment_item(text: String) -> Item {
  CommentItem(comment(text))
}

/// Wrap an already-validated `Comment` as a stream item. Companion
/// to `comment_checked/1` so callers can keep the typed-error
/// pipeline `text -> Result(Comment, EventError) -> Result(Item, _)`
/// without reaching into `Item`'s constructors. (#81)
pub fn comment_item_of(c: Comment) -> Item {
  CommentItem(c)
}

/// Issue #77: Item-level accessors. The `Item` variants `EventItem` /
/// `CommentItem` are not visible through the top-level `ssevents`
/// module (a Gleam type alias does not re-export its constructors), so
/// callers that decode an SSE stream and want to pattern-match on the
/// result would otherwise need to reach into `ssevents/event` directly.
/// These helpers let `ssevents`-only callers walk decoded items without
/// the second import.
/// `True` when the item is an event (carries an SSE `Event` payload).
pub fn is_event(item: Item) -> Bool {
  case item {
    EventItem(_) -> True
    CommentItem(_) -> False
  }
}

/// `True` when the item is a `:`-prefixed comment line.
pub fn is_comment(item: Item) -> Bool {
  case item {
    CommentItem(_) -> True
    EventItem(_) -> False
  }
}

/// Return the event payload when the item is an event, `None`
/// otherwise. Use with `option.then` / `case` for stream processing
/// that ignores comments.
pub fn event_of_item(item: Item) -> Option(Event) {
  case item {
    EventItem(ev) -> Some(ev)
    CommentItem(_) -> None
  }
}

/// Return the comment text when the item is a comment, `None`
/// otherwise. Mirrors `event_of_item/1` for the comment side.
pub fn comment_text_of_item(item: Item) -> Option(String) {
  case item {
    CommentItem(c) -> Some(comment_text_of(c))
    EventItem(_) -> None
  }
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
  // Issue #89: align with the `retry/2` setter. A negative `retry`
  // value is a programmer error — the SSE spec mandates a
  // non-negative reconnection time. Pre-fix `sanitize_retry`
  // silently dropped it to `None`, which left callers with no
  // signal that their input was rejected. Now we panic on the
  // negative case (matching `retry/2`); values above
  // `default_max_retry_value` still drop to `None` so the
  // `decode(encode(_))` round-trip property holds — that branch is
  // documented on `retry/2` and is consistent across all three
  // setters.
  case retry {
    Some(ms) if ms < 0 ->
      panic as {
        "ssevents.from_parts: retry milliseconds must be >= 0 (got "
        <> int.to_string(ms)
        <> "); the SSE spec mandates a non-negative reconnection time. Use retry_clamp via the builder if a lenient posture is wanted."
      }
    _ -> Nil
  }
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

/// Build an event with both `name` and `data`. CR / LF / NUL bytes
/// in `name` are silently stripped — see the warning on `event/2`.
/// Reach for `named_checked/2` when the bad-input case must be
/// surfaced as a typed error. (#81)
pub fn named(name: String, data: String) -> Event {
  new(data) |> event(name)
}

/// Set the SSE `event:` field name on an event. CR / LF / NUL bytes
/// are silently stripped to keep the wire spec-compliant — so
/// `named("\n", _)` produces an event with `name = ""`. The strip
/// is data loss the caller cannot observe; reach for
/// `event_checked/2` when the name comes from user-typed or
/// upstream input and a typed error is preferable to silent data
/// loss. (#81)
pub fn event(event: Event, name: String) -> Event {
  Event(
    event: Some(sanitize_field_value(name)),
    data: event.data,
    id: event.id,
    retry: event.retry,
  )
}

/// Set the SSE `id:` Last-Event-ID on an event. CR / LF / NUL bytes
/// are silently stripped — so `id(_, "ab\u{0000}cd")` produces an
/// event with `id = "abcd"`, a *different valid id*, which can
/// silently match the wrong subscription channel on reconnect.
/// Reach for `id_checked/2` when the id comes from user-typed or
/// upstream input and a typed error is preferable to silent
/// authorization-relevant identifier mutation. (#81)
pub fn id(event: Event, id: String) -> Event {
  Event(
    event: event.event,
    data: event.data,
    id: Some(sanitize_field_value(id)),
    retry: event.retry,
  )
}

/// Strict counterpart of `event/2`: rejects names containing CR /
/// LF / NUL bytes with `Error(NameContainsControlBytes(value:))`.
///
/// The non-strict `event/2` silently strips these bytes (so
/// `named("\n", _)` produces a part with `name = ""`). For callers
/// passing user-typed or upstream data into the event name and want
/// to surface bad inputs as a typed error rather than silent data
/// loss, use this variant. The `value` payload carries the
/// caller's original input so the error renders as
/// "event name `foo\\nbar` contains forbidden control bytes". (#81)
pub fn event_checked(
  source_event: Event,
  name: String,
) -> Result(Event, EventError) {
  case has_forbidden_byte(name) {
    True -> Error(NameContainsControlBytes(value: name))
    False -> Ok(event(source_event, name))
  }
}

/// Strict counterpart of `id/2`: rejects ids containing CR / LF /
/// NUL bytes with `Error(IdContainsControlBytes(value:))`.
///
/// The non-strict `id/2` silently strips these bytes. The strip on
/// the id is especially dangerous — `id(_, "ab\u{0000}cd")`
/// produces an event with `id = "abcd"`, a *different valid id*,
/// which can silently match the wrong subscription channel on
/// reconnect (Last-Event-ID resume). The strict variant catches
/// this at the builder boundary so the wrong wire never gets
/// produced. (#81)
pub fn id_checked(event: Event, id: String) -> Result(Event, EventError) {
  case has_forbidden_byte(id) {
    True -> Error(IdContainsControlBytes(value: id))
    False -> Ok(id_internal(event, id))
  }
}

fn id_internal(event: Event, id_value: String) -> Event {
  Event(
    event: event.event,
    data: event.data,
    id: Some(sanitize_field_value(id_value)),
    retry: event.retry,
  )
}

/// Strict counterpart of `named/2`: rejects names containing CR /
/// LF / NUL bytes with `Error(NameContainsControlBytes(value:))`.
///
/// Convenience for the common `new |> event_checked` pipeline that
/// also constructs a fresh `Event`. (#81)
pub fn named_checked(name: String, data: String) -> Result(Event, EventError) {
  event_checked(new(data), name)
}

/// Strict counterpart of `comment/1`: rejects comment text
/// containing CR / LF / NUL bytes with
/// `Error(CommentContainsControlBytes(value:))`.
///
/// The non-strict `comment/1` silently strips these bytes.
/// WHATWG SSE §9.2.6 has no notion of a multi-line comment, so
/// embedded line breaks would fan out into multiple comments on
/// the wire; the strict variant surfaces this as an explicit
/// error rather than silently splitting the caller's intent. (#81)
pub fn comment_checked(text: String) -> Result(Comment, EventError) {
  case has_forbidden_byte(text) {
    True -> Error(CommentContainsControlBytes(value: text))
    False -> Ok(comment(text))
  }
}

fn has_forbidden_byte(value: String) -> Bool {
  string.contains(value, "\r")
  || string.contains(value, "\n")
  || string.contains(value, "\u{0000}")
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

/// Set the SSE `retry:` reconnection time on an event.
///
/// `milliseconds` must be `>= 0`. WHATWG SSE §9.2.6 only recognises a
/// retry value whose textual form "consists of only ASCII digits", so a
/// negative value would be either dropped on the wire (the leading `-`
/// breaks the digits-only check) or interpreted as `0` and trigger a
/// tight reconnect loop against the server. Either outcome is a
/// contract violation, so the builder panics on `ms < 0` with
/// `"ssevents.retry: milliseconds must be >= 0 (got <n>); the SSE spec
/// mandates a non-negative reconnection time."`. Use `retry_clamp/2`
/// instead when the caller wants the lenient (clamp-to-`0`) behaviour.
///
/// Values above `limit.default_max_retry_value` (24 h in ms) are still
/// silently dropped to `None`, matching `from_parts/4` and the
/// `decode(encode(_))` round-trip property pinned in #60.
pub fn retry(event: Event, milliseconds: Int) -> Event {
  case milliseconds < 0 {
    True ->
      panic as {
        "ssevents.retry: milliseconds must be >= 0 (got "
        <> int.to_string(milliseconds)
        <> "); the SSE spec mandates a non-negative reconnection time."
      }
    False ->
      Event(
        event: event.event,
        data: event.data,
        id: event.id,
        retry: sanitize_retry(Some(milliseconds)),
      )
  }
}

/// Like `retry/2`, but clamps `milliseconds < 0` to `0` instead of
/// panicking. Use this when the caller wants the lenient posture
/// (e.g. when forwarding a value computed from possibly-noisy input).
/// All other behaviour matches `retry/2`, including the `> max_retry`
/// silent drop to `None` for round-trip with the default decoder.
pub fn retry_clamp(event: Event, milliseconds: Int) -> Event {
  let clamped = case milliseconds < 0 {
    True -> 0
    False -> milliseconds
  }
  Event(
    event: event.event,
    data: event.data,
    id: event.id,
    retry: sanitize_retry(Some(clamped)),
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
