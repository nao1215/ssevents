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

import gleam/option.{type Option}
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

pub fn retry(event: Event, milliseconds: Int) -> Event {
  event.retry(event, milliseconds)
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
