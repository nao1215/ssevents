//// Encode a few SSE items, print the wire text, and decode it back.
////
////    cd examples/quick_start
////    gleam run

import gleam/io
import gleam/list
import gleam/string
import ssevents.{CommentItem, EventItem}

pub fn main() {
  let body =
    ssevents.encode_items([
      ssevents.comment("stream opened"),
      ssevents.named("job.started", "build #42")
        |> ssevents.id("cursor-1")
        |> ssevents.retry(5000)
        |> EventItem,
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
    }
  })
}
