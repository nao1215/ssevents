import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import ssevents
import ssevents/encoder

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

pub fn encode_event_with_crlf_test() {
  ssevents.new("test")
  |> ssevents.encode_with_line_ending(encoder.Crlf)
  |> should.equal("data: test\r\n\r\n")
}

pub fn encode_multiline_event_with_crlf_test() {
  let event =
    ssevents.named("job.update", "line1\nline2")
    |> ssevents.id("cursor-1")

  ssevents.encode_with_line_ending(event, encoder.Crlf)
  |> should.equal(
    "event: job.update\r\nid: cursor-1\r\ndata: line1\r\ndata: line2\r\n\r\n",
  )
}

pub fn encode_comment_with_crlf_test() {
  ssevents.comment("hello")
  |> ssevents.encode_item_with_line_ending(encoder.Crlf)
  |> should.equal(": hello\r\n")
}

pub fn encode_items_with_crlf_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.new("payload") |> ssevents.event_item,
  ]

  let encoded = ssevents.encode_items_with_line_ending(items, encoder.Crlf)
  encoded |> should.equal(": meta\r\ndata: payload\r\n\r\n")

  let assert Ok(decoded) = ssevents.decode(encoded)
  decoded |> should.equal(items)
}

pub fn encode_bytes_matches_string_encoding_test() {
  let event =
    ssevents.named("job.update", "payload")
    |> ssevents.id("cursor-1")

  ssevents.encode_bytes(event)
  |> should.equal(bit_array.from_string(ssevents.encode(event)))
}

pub fn encode_item_bytes_matches_string_encoding_test() {
  let item = ssevents.comment("meta")

  ssevents.encode_item_bytes(item)
  |> should.equal(bit_array.from_string(ssevents.encode_item(item)))
}

pub fn encode_items_bytes_matches_item_concatenation_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.new("payload") |> ssevents.event_item,
  ]

  ssevents.encode_items_bytes(items)
  |> should.equal(
    items
    |> list.map(ssevents.encode_item_bytes)
    |> bit_array.concat,
  )
}
