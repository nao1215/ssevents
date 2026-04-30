//// Build the sequence of byte chunks an HTTP server would write to a
//// `text/event-stream` response body. The chunks are runtime-agnostic
//// — pipe them into the response writer of whichever framework you
//// use (Mist, Wisp, your own).
////
////    cd examples/server_emit
////    gleam run
////
//// HTTP-level concerns (which the example deliberately does NOT pull
//// in as dependencies) are documented in `examples/README.md` and
//// echoed in the program's output.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import ssevents

pub fn main() {
  io.println("# Required HTTP response headers")
  list.each(response_headers(), fn(pair) {
    let #(name, value) = pair
    io.println("  " <> name <> ": " <> value)
  })

  io.println("\n# Wire chunks the server would write to the response body")

  let chunks = stream_chunks()
  list.each(chunks, fn(chunk) {
    case bit_array.to_string(chunk) {
      Ok(text) -> io.println("--- chunk ---\n" <> text)
      Error(_) ->
        io.println(
          "--- chunk (binary, "
          <> int.to_string(bit_array.byte_size(chunk))
          <> " bytes) ---",
        )
    }
  })

  let total =
    list.fold(chunks, 0, fn(acc, chunk) { acc + bit_array.byte_size(chunk) })
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

/// One encoded `BitArray` per logical write. Each encoded item ends in
/// a blank line, so the client decoder can dispatch as soon as the
/// chunk lands — there is no need to coalesce writes.
fn stream_chunks() -> List(BitArray) {
  let opening = [
    ssevents.comment("stream opened"),
    ssevents.named("retry.hint", "use 5s")
      |> ssevents.retry(5000)
      |> ssevents.event_item,
  ]

  let updates = [
    ssevents.named("job.started", "build #42")
      |> ssevents.id("cursor-1")
      |> ssevents.event_item,
    ssevents.named("job.progress", "step 1/3\nrunning lints")
      |> ssevents.id("cursor-2")
      |> ssevents.event_item,
    ssevents.heartbeat(),
    ssevents.named("job.finished", "ok")
      |> ssevents.id("cursor-3")
      |> ssevents.event_item,
  ]

  [
    ssevents.encode_items_bytes(opening),
    ..list.map(updates, ssevents.encode_item_bytes)
  ]
}
