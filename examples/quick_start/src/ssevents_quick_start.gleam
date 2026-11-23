//// Encode a few SSE items, print the wire text, and decode it back.
////
////    cd examples/quick_start
////    gleam run

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import ssevents.{CommentItem, EventItem, ReconnectItem}

pub fn main() {
  let assert Ok(opened) = ssevents.comment("stream opened")
  let assert Ok(started) =
    ssevents.named("job.started", "build #42")
    |> result.try(ssevents.id(_, "cursor-1"))
  let body =
    ssevents.encode_items([
      opened,
      ReconnectItem(id: None, retry: Some(5000)),
      EventItem(started),
      EventItem(ssevents.new("step 1/3\nrunning lints")),
    ])
  io.print(body)

  let assert Ok(items) = ssevents.decode(<<body:utf8>>, ssevents.default_limits)
  list.each(items, fn(item) {
    case item {
      EventItem(event) ->
        io.println("event data: " <> string.inspect(ssevents.data_of(event)))
      CommentItem(comment) ->
        io.println("comment: " <> ssevents.comment_text(comment))
      ReconnectItem(retry: Some(ms), ..) ->
        io.println("retry: " <> int.to_string(ms))
      ReconnectItem(..) -> Nil
    }
  })
}
