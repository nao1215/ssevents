//// Build the chunks an HTTP server would write to a `text/event-stream`
//// response body. Hand them to the response writer of whichever
//// framework you use (Mist, Wisp or your own).
////
////    cd examples/server_emit
////    gleam run
////
//// The HTTP headers are described in `examples/README.md` and printed
//// by the program.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import ssevents.{EventItem, ReconnectItem}

pub fn main() {
  io.println("# Required HTTP response headers")
  list.each(response_headers(), fn(pair) {
    let #(name, value) = pair
    io.println("  " <> name <> ": " <> value)
  })

  io.println("\n# Wire chunks the server would write to the response body")

  let chunks = stream_chunks()
  list.each(chunks, fn(chunk) { io.println("--- chunk ---\n" <> chunk) })

  let total =
    list.fold(chunks, 0, fn(acc, chunk) { acc + string.byte_size(chunk) })
  io.println(
    "\n# Total: "
    <> int.to_string(list.length(chunks))
    <> " chunks, "
    <> int.to_string(total)
    <> " bytes",
  )
}

/// The header set every SSE endpoint should send. `Cache-Control` and
/// `X-Accel-Buffering` matter especially when an upstream proxy
/// (nginx, ingress controllers) might otherwise buffer the response.
pub fn response_headers() -> List(#(String, String)) {
  [
    #("Content-Type", ssevents.content_type()),
    #("Cache-Control", "no-cache, no-transform"),
    #("Connection", "keep-alive"),
    #("X-Accel-Buffering", "no"),
  ]
}

/// One encoded chunk per write. Each event ends in a blank line, so a
/// client dispatches it as soon as the chunk arrives.
fn stream_chunks() -> List(String) {
  // The names, ids and comments are literals without line breaks, so the
  // builders cannot fail here.
  let assert Ok(opened) = ssevents.comment("stream opened")
  let assert Ok(heartbeat) = ssevents.comment("heartbeat")
  let assert Ok([started, progress, finished]) =
    [
      #("job.started", "build #42", "cursor-1"),
      #("job.progress", "step 1/3\nrunning lints", "cursor-2"),
      #("job.finished", "ok", "cursor-3"),
    ]
    |> list.try_map(fn(update) {
      let #(name, data, id) = update
      ssevents.named(name, data)
      |> result.try(ssevents.id(_, id))
      |> result.map(EventItem)
    })

  // A block without data tells the client how long to wait before it
  // reconnects, without dispatching an event.
  let opening = [opened, ReconnectItem(id: None, retry: Some(5000))]
  let updates = [started, progress, heartbeat, finished]

  [
    ssevents.encode_items(opening),
    ..list.map(updates, fn(item) { ssevents.encode_items([item]) })
  ]
}
