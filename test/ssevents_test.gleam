import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import ssevents
import ssevents/error.{EventTooLarge, InvalidRetry, LineTooLong}
import ssevents/event.{Comment, EventItem}
import ssevents/stream

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn package_name_matches_repository_test() {
  ssevents.package_name
  |> should.equal("ssevents")
}

pub fn event_builder_accessors_test() {
  let event =
    ssevents.new("payload")
    |> ssevents.event("job.update")
    |> ssevents.id("job-1")
    |> ssevents.retry(5000)

  ssevents.event_name(event) |> should.equal(Some("job.update"))
  ssevents.data_of(event) |> should.equal("payload")
  ssevents.id_of(event) |> should.equal(Some("job-1"))
  ssevents.retry_of(event) |> should.equal(Some(5000))
}

pub fn encode_multiline_event_with_lf_test() {
  let event =
    ssevents.from_parts(
      event_name: Some("update"),
      data: "line1\nline2",
      id: Some("abc"),
      retry: Some(2500),
    )

  ssevents.encode(event)
  |> should.equal(
    "event: update\nid: abc\nretry: 2500\ndata: line1\ndata: line2\n\n",
  )
}

pub fn encode_comment_and_heartbeat_test() {
  ssevents.comment("keepalive")
  |> ssevents.encode_item
  |> should.equal(": keepalive\n")

  ssevents.heartbeat()
  |> ssevents.encode_item
  |> should.equal(": heartbeat\n")
}

pub fn encode_empty_data_event_emits_explicit_data_line_test() {
  ssevents.new("")
  |> ssevents.encode
  |> should.equal("data:\n\n")
}

pub fn decode_simple_event_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("event: ping\ndata: hello\nid: 1\nretry: 1000\n\n")

  ssevents.event_name(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
  ssevents.id_of(event) |> should.equal(Some("1"))
  ssevents.retry_of(event) |> should.equal(Some(1000))
}

pub fn decode_comment_and_event_test() {
  let assert Ok(items) = ssevents.decode(": hello\ndata: world\n\n")
  items |> should.equal([Comment("hello"), EventItem(ssevents.new("world"))])
}

pub fn decode_unknown_fields_are_ignored_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("foo: bar\ndata: ok\nanother\n\n")

  ssevents.data_of(event) |> should.equal("ok")
  ssevents.event_name(event) |> should.equal(None)
}

pub fn decode_crlf_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("event: ping\r\ndata: hello\r\n\r\n")

  ssevents.event_name(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
}

pub fn decode_final_unterminated_event_is_dispatched_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("data: tail")
  ssevents.data_of(event) |> should.equal("tail")
}

pub fn decode_retry_only_event_is_preserved_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("retry: 1500\n\n")
  ssevents.data_of(event) |> should.equal("")
  ssevents.retry_of(event) |> should.equal(Some(1500))
}

pub fn decode_empty_data_event_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("data:\n\n")
  ssevents.data_of(event) |> should.equal("")
}

pub fn decode_invalid_retry_test() {
  ssevents.decode("retry: nope\n\n")
  |> should.equal(Error(InvalidRetry("nope")))
}

pub fn decode_line_too_long_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 4,
      max_event_bytes: 100,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode_with_limits("data: hello\n\n", limits: limits)
  |> should.equal(Error(LineTooLong(4)))
}

pub fn decode_event_too_large_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 100,
      max_event_bytes: 8,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode_with_limits("data: hello\n\n", limits: limits)
  |> should.equal(Error(EventTooLarge(8)))
}

pub fn incremental_push_handles_partial_chunks_test() {
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) =
    state |> ssevents.push(bit_array.from_string("data: hel"))
  items1 |> should.equal([])

  let assert Ok(#(state, items2)) =
    state |> ssevents.push(bit_array.from_string("lo\n\n"))
  items2 |> should.equal([EventItem(ssevents.new("hello"))])

  let assert Ok(items3) = ssevents.finish(state)
  items3 |> should.equal([])
}

pub fn incremental_push_handles_split_utf8_test() {
  let full = bit_array.from_string("data: 😀\n\n")
  let assert Ok(chunk1) = bit_array.slice(from: full, at: 0, take: 8)
  let assert Ok(chunk2) =
    bit_array.slice(from: full, at: 8, take: bit_array.byte_size(full) - 8)

  let assert Ok(#(state, items1)) =
    ssevents.push(ssevents.new_decoder(), chunk1)
  items1 |> should.equal([])

  let assert Ok(#(_state, items2)) = ssevents.push(state, chunk2)
  items2 |> should.equal([EventItem(ssevents.new("😀"))])
}

pub fn encode_decode_roundtrip_items_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.named("job.started", "hello\nworld")
      |> ssevents.id("cursor-1")
      |> ssevents.retry(2000)
      |> ssevents.event_item,
    ssevents.new("") |> ssevents.event_item,
  ]

  let assert Ok(decoded) = items |> ssevents.encode_items |> ssevents.decode
  decoded |> should.equal(items)
}

pub fn reconnect_state_tracks_last_id_and_retry_test() {
  let state =
    ssevents.new_reconnect_state()
    |> ssevents.update_reconnect(ssevents.comment("ignore"))
    |> ssevents.update_reconnect(
      ssevents.named("job", "payload")
      |> ssevents.id("cursor-99")
      |> ssevents.retry(1500)
      |> ssevents.event_item,
    )

  ssevents.last_event_id(state) |> should.equal(Some("cursor-99"))
  ssevents.retry_interval(state) |> should.equal(Some(1500))
  ssevents.last_event_id_header(state)
  |> should.equal(Some(#("Last-Event-ID", "cursor-99")))
}

pub fn validation_helpers_test() {
  ssevents.validate_event_name("ok") |> should.equal(Ok("ok"))
  ssevents.validate_id("id-1") |> should.equal(Ok("id-1"))
  ssevents.validate_retry(0) |> should.equal(Ok(0))
  ssevents.validate_retry(-1) |> should.equal(Error(InvalidRetry("-1")))
}

pub fn stream_encode_stream_test() {
  let items = [
    ssevents.comment("a"),
    ssevents.new("b") |> ssevents.event_item,
  ]

  stream.from_list(items)
  |> ssevents.encode_stream
  |> stream.to_list
  |> should.equal(list.map(items, ssevents.encode_item_bytes))
}

pub fn stream_decode_stream_test() {
  let chunks =
    [
      bit_array.from_string(": hi\n"),
      bit_array.from_string("data: x\n\n"),
    ]
    |> stream.from_list

  chunks
  |> ssevents.decode_stream
  |> stream.to_list
  |> should.equal([Ok(Comment("hi")), Ok(EventItem(ssevents.new("x")))])
}
