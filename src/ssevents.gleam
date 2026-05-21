//// Canonical public surface for the `ssevents` package.
////
//// The focused modules (`ssevents/event`, `ssevents/encoder`,
//// `ssevents/decoder`, `ssevents/reconnect`, `ssevents/validate`,
//// `ssevents/limit`, `ssevents/heartbeat`, `ssevents/stream`,
//// `ssevents/error`) carry the actual implementation, but they are an
//// implementation detail: external code should prefer the spellings
//// re-exported here. This is the surface the README and the published
//// HexDocs documentation consider authoritative, and it is the surface
//// that follows semver — the submodule shapes may be reorganized
//// between releases.
////
//// Reach into a submodule directly only when the facade does not yet
//// expose what you need; in that case, opening an issue so the
//// missing entry point can be added at this level is preferred to
//// scattering submodule imports across user code.

import gleam/list
import gleam/option.{type Option, None, Some}
import ssevents/decoder
import ssevents/encoder
import ssevents/error
import ssevents/event
import ssevents/heartbeat
import ssevents/limit
import ssevents/reconnect
import ssevents/stream
import ssevents/validate

pub const package_name = "ssevents"

pub const default_content_type = "text/event-stream"

pub type Event =
  event.Event

pub type Item =
  event.Item

pub type DecodeState =
  decoder.DecodeState

pub type Limits =
  limit.Limits

pub type LineEnding =
  encoder.LineEnding

pub type ReconnectState =
  reconnect.ReconnectState

pub type SseError =
  error.SseError

/// Re-export of `ssevents/event.EventError`.
pub type EventError =
  event.EventError

pub type Iterator(a) =
  stream.Iterator(a)

pub type IteratorStep(a) =
  stream.Step(a)

pub fn content_type() -> String {
  default_content_type
}

pub fn default_limits() -> Limits {
  limit.default()
}

pub fn new(data: String) -> Event {
  event.new(data)
}

pub fn from_parts(
  event_name event_name: Option(String),
  data data: String,
  id id: Option(String),
  retry retry: Option(Int),
) -> Event {
  event.from_parts(event_name: event_name, data: data, id: id, retry: retry)
}

pub fn message(data: String) -> Event {
  event.message(data)
}

pub fn named(name: String, data: String) -> Event {
  event.named(name, data)
}

pub fn name_of(event: Event) -> Option(String) {
  event.name_of(event)
}

pub fn data_of(event: Event) -> String {
  event.data_of(event)
}

pub fn id_of(event: Event) -> Option(String) {
  event.id_of(event)
}

pub fn retry_of(event: Event) -> Option(Int) {
  event.retry_of(event)
}

pub fn event(event: Event, name: String) -> Event {
  event.event(event, name)
}

pub fn id(event: Event, id: String) -> Event {
  event.id(event, id)
}

/// Strict counterpart of `event/2`: returns
/// `Error(NameContainsControlBytes(value:))` when the name
/// contains CR / LF / NUL bytes, otherwise sets the SSE
/// `event:` field name. Use when the name comes from user-typed
/// or upstream input and silent stripping would lose data the
/// caller cares about. (#81)
pub fn event_checked(event: Event, name: String) -> Result(Event, EventError) {
  event.event_checked(event, name)
}

/// Strict counterpart of `id/2`: returns
/// `Error(IdContainsControlBytes(value:))` when the id contains
/// CR / LF / NUL bytes. The strip on id is especially dangerous —
/// `id(_, "ab\u{0000}cd")` produces an event with `id = "abcd"`,
/// silently mutating an authorisation-relevant identifier on
/// reconnect (Last-Event-ID resume). The strict variant catches
/// this at the builder boundary. (#81)
pub fn id_checked(event: Event, id: String) -> Result(Event, EventError) {
  event.id_checked(event, id)
}

/// Strict counterpart of `named/2`: returns
/// `Error(NameContainsControlBytes(value:))` when the name
/// contains CR / LF / NUL bytes. Convenience for the common
/// `new |> event_checked` pipeline. (#81)
pub fn named_checked(name: String, data: String) -> Result(Event, EventError) {
  event.named_checked(name, data)
}

/// Strict counterpart of `comment/1`: returns
/// `Error(CommentContainsControlBytes(value:))` when the comment
/// text contains CR / LF / NUL bytes. The non-strict `comment/1`
/// silently strips these bytes; WHATWG SSE §9.2.6 has no notion
/// of a multi-line comment, so embedded line breaks would fan out
/// into multiple comments on the wire. (#81)
pub fn comment_checked(text: String) -> Result(Item, EventError) {
  case event.comment_checked(text) {
    Ok(comment) -> Ok(event.comment_item_of(comment))
    Error(error_value) -> Error(error_value)
  }
}

/// Set the SSE `retry:` reconnection time on an event.
///
/// `milliseconds` must be `>= 0`. WHATWG SSE §9.2.6 only recognises a
/// retry value whose textual form "consists of only ASCII digits", so a
/// negative value would be either dropped on the wire (the leading `-`
/// breaks the digits-only check) or interpreted as `0` and trigger a
/// tight reconnect loop against the server. The builder panics on
/// `ms < 0`; reach for `retry_clamp/2` when the caller wants the
/// lenient (clamp-to-`0`) posture.
pub fn retry(event: Event, milliseconds: Int) -> Event {
  event.retry(event, milliseconds)
}

/// Like `retry/2`, but clamps `milliseconds < 0` to `0` instead of
/// panicking. Use this when forwarding a value computed from possibly-
/// noisy input (e.g. a CLI flag, a deserialised config) and the caller
/// would rather "publish a spec-valid retry" than crash.
pub fn retry_clamp(event: Event, milliseconds: Int) -> Event {
  event.retry_clamp(event, milliseconds)
}

pub fn data(event: Event, data: String) -> Event {
  event.data(event, data)
}

pub fn event_item(event: Event) -> Item {
  event.event_item(event)
}

pub fn comment(text: String) -> Item {
  heartbeat.comment(text)
}

pub fn heartbeat() -> Item {
  heartbeat.heartbeat()
}

/// Issue #77: Item-level inspection helpers exposed through the
/// facade. The `Item` type is re-exported as a type alias from this
/// module, but Gleam's type aliases do not carry the underlying
/// `EventItem` / `CommentItem` constructors — pattern-matching on a
/// decoded `Item` therefore requires reaching into
/// `ssevents/event` for the variants. These accessors let callers stay
/// inside the facade for the common cases.
/// `True` when the item is an event (carries an SSE `Event` payload).
pub fn is_event(item: Item) -> Bool {
  event.is_event(item)
}

/// `True` when the item is a `:`-prefixed comment line.
pub fn is_comment(item: Item) -> Bool {
  event.is_comment(item)
}

/// Return the event payload when the item is an event, `None`
/// otherwise. Pairs with `comment_text_of_item/1` for the comment
/// side.
pub fn event_of_item(item: Item) -> Option(Event) {
  event.event_of_item(item)
}

/// Return the comment text when the item is a comment, `None`
/// otherwise.
pub fn comment_text_of_item(item: Item) -> Option(String) {
  event.comment_text_of_item(item)
}

/// Filter a decoded item list down to its events, dropping comments.
/// Convenience for the common "I just want the events" pattern after
/// `decode/1`.
pub fn events_of(items: List(Item)) -> List(Event) {
  list.filter_map(items, fn(item) {
    case event.event_of_item(item) {
      Some(ev) -> Ok(ev)
      None -> Error(Nil)
    }
  })
}

/// Filter a decoded item list down to its comment texts, dropping
/// events. Pairs with `events_of/1`.
pub fn comment_texts_of(items: List(Item)) -> List(String) {
  list.filter_map(items, fn(item) {
    case event.comment_text_of_item(item) {
      Some(text) -> Ok(text)
      None -> Error(Nil)
    }
  })
}

pub fn default_line_ending() -> LineEnding {
  encoder.default_line_ending()
}

/// Encode one semantic SSE `Event` to its wire-format `String`.
///
/// Use this when you want a text representation for logging,
/// inspection, fixtures, or a caller that still expects `String`.
pub fn encode(event: Event) -> String {
  encoder.encode(event)
}

/// Encode one semantic SSE `Event` to its wire-format `BitArray`.
///
/// Use this for HTTP responses and other byte-oriented transports.
pub fn encode_bytes(event: Event) -> BitArray {
  encoder.encode_bytes(event)
}

/// Encode one `Item` (either an event or a comment) to `String`.
pub fn encode_item(item: Item) -> String {
  encoder.encode_item(item)
}

/// Encode one `Item` (either an event or a comment) to `BitArray`.
pub fn encode_item_bytes(item: Item) -> BitArray {
  encoder.encode_item_bytes(item)
}

/// Encode a whole sequence of SSE items to one `String`.
pub fn encode_items(items: List(Item)) -> String {
  encoder.encode_items(items)
}

/// Encode a whole sequence of SSE items to one `BitArray`.
pub fn encode_items_bytes(items: List(Item)) -> BitArray {
  encoder.encode_items_bytes(items)
}

pub fn encode_with_line_ending(event: Event, line_ending: LineEnding) -> String {
  encoder.encode_with_line_ending(event, line_ending)
}

pub fn encode_item_with_line_ending(
  item: Item,
  line_ending: LineEnding,
) -> String {
  encoder.encode_item_with_line_ending(item, line_ending)
}

pub fn encode_items_with_line_ending(
  items: List(Item),
  line_ending: LineEnding,
) -> String {
  encoder.encode_items_with_line_ending(items, line_ending)
}

pub fn decode(input: String) -> Result(List(Item), SseError) {
  decoder.decode(input)
}

pub fn decode_bytes(input: BitArray) -> Result(List(Item), SseError) {
  decoder.decode_bytes(input)
}

pub fn decode_with_limits(
  input: String,
  limits limits: Limits,
) -> Result(List(Item), SseError) {
  decoder.decode_with_limits(input, limits: limits)
}

pub fn decode_bytes_with_limits(
  input: BitArray,
  limits limits: Limits,
) -> Result(List(Item), SseError) {
  decoder.decode_bytes_with_limits(input, limits: limits)
}

pub fn new_decoder() -> DecodeState {
  decoder.new_decoder()
}

pub fn new_decoder_with_limits(limits: Limits) -> DecodeState {
  decoder.new_decoder_with_limits(limits)
}

pub fn push(
  state: DecodeState,
  chunk: BitArray,
) -> Result(#(DecodeState, List(Item)), SseError) {
  decoder.push(state, chunk)
}

pub fn finish(state: DecodeState) -> Result(List(Item), SseError) {
  decoder.finish(state)
}

pub fn limits() -> Limits {
  limit.default()
}

pub fn new_limits(
  max_line_bytes max_line_bytes: Int,
  max_event_bytes max_event_bytes: Int,
  max_data_lines max_data_lines: Int,
  max_retry_value max_retry_value: Int,
) -> Limits {
  limit.new(
    max_line_bytes: max_line_bytes,
    max_event_bytes: max_event_bytes,
    max_data_lines: max_data_lines,
    max_retry_value: max_retry_value,
  )
}

pub fn max_line_bytes(limits: Limits) -> Int {
  limit.max_line_bytes(limits)
}

pub fn max_event_bytes(limits: Limits) -> Int {
  limit.max_event_bytes(limits)
}

pub fn max_data_lines(limits: Limits) -> Int {
  limit.max_data_lines(limits)
}

pub fn max_retry_value(limits: Limits) -> Int {
  limit.max_retry_value(limits)
}

/// Read the `strict_retry_cap` flag from a `Limits` value.
///
/// When `True`, the decoder errors with `InvalidRetry(_)` on
/// `retry:` values above `max_retry_value`. When `False` (the
/// default), the decoder silently drops the offending field to
/// `None` and the surrounding event still dispatches. (#95)
pub fn strict_retry_cap(limits: Limits) -> Bool {
  limit.strict_retry_cap(limits)
}

/// Toggle the decoder's `retry:` cap-overrun posture.
///
/// `False` (the default) keeps the decoder lenient: a `retry:` value
/// above `max_retry_value` is silently dropped to `None` and the
/// surrounding event still dispatches, mirroring the encoder's
/// `retry_clamp/2` and matching WHATWG SSE's lenient parser thesis.
/// `True` re-enables the strict posture: an above-cap value fails
/// the whole decode with `Error(InvalidRetry(_))`, so callers that
/// want to detect adversarial retry values explicitly can do so.
/// (#95)
pub fn with_strict_retry_cap(limits: Limits, strict: Bool) -> Limits {
  limit.with_strict_retry_cap(limits, strict)
}

pub fn validate_event_name(name: String) -> Result(String, SseError) {
  validate.validate_event_name(name)
}

pub fn validate_id(id: String) -> Result(String, SseError) {
  validate.validate_id(id)
}

pub fn validate_retry(milliseconds: Int) -> Result(Int, SseError) {
  validate.validate_retry(milliseconds)
}

pub fn max_data_bytes(event: Event, max: Int) -> Result(Event, SseError) {
  validate.max_data_bytes(event, max: max)
}

pub fn new_reconnect_state() -> ReconnectState {
  reconnect.new()
}

pub fn update_reconnect(state: ReconnectState, item: Item) -> ReconnectState {
  reconnect.update(state, item)
}

pub fn last_event_id(state: ReconnectState) -> Option(String) {
  reconnect.last_event_id(state)
}

pub fn retry_interval(state: ReconnectState) -> Option(Int) {
  reconnect.retry(state)
}

pub fn last_event_id_header(state: ReconnectState) -> Option(#(String, String)) {
  reconnect.last_event_id_header(state)
}

pub fn empty_iterator() -> Iterator(a) {
  stream.empty()
}

pub fn iterator_from_list(items: List(a)) -> Iterator(a) {
  stream.from_list(items)
}

pub fn iterator_to_list(iterator: Iterator(a)) -> List(a) {
  stream.to_list(iterator)
}

pub fn iterator_next(iterator: Iterator(a)) -> IteratorStep(a) {
  stream.next(iterator)
}

pub fn encode_stream(items: Iterator(Item)) -> Iterator(BitArray) {
  stream.encode_stream(items)
}

pub fn decode_stream(
  chunks: Iterator(BitArray),
) -> Iterator(Result(Item, SseError)) {
  stream.decode_stream(chunks)
}

pub fn decode_stream_with_limits(
  chunks: Iterator(BitArray),
  limits limits: Limits,
) -> Iterator(Result(Item, SseError)) {
  stream.decode_stream_with_limits(chunks, limits: limits)
}

pub fn error_to_string(error: SseError) -> String {
  error.to_string(error)
}
