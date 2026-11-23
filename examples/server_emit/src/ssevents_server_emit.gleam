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
import gleam/string
import ssevents.{EventItem}

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
  let opening = [
    ssevents.comment("stream opened"),
    ssevents.named("retry.hint", "use 5s")
      |> ssevents.retry(5000)
      |> EventItem,
  ]

  let updates = [
    ssevents.named("job.started", "build #42")
      |> ssevents.id("cursor-1")
      |> EventItem,
    ssevents.named("job.progress", "step 1/3\nrunning lints")
      |> ssevents.id("cursor-2")
      |> EventItem,
    ssevents.comment("heartbeat"),
    ssevents.named("job.finished", "ok")
      |> ssevents.id("cursor-3")
      |> EventItem,
  ]

  [
    ssevents.encode_items(opening),
    ..list.map(updates, fn(item) { ssevents.encode_items([item]) })
  ]
}
