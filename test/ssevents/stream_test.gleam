import gleam/bit_array
import gleam/list
import gleeunit/should
import ssevents
import ssevents/event.{Comment, EventItem}
import ssevents/stream

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
    [bit_array.from_string(": hi\n"), bit_array.from_string("data: x\n\n")]
    |> stream.from_list

  chunks
  |> ssevents.decode_stream
  |> stream.to_list
  |> should.equal([Ok(Comment("hi")), Ok(EventItem(ssevents.new("x")))])
}
