//// The shortest "first success" path: build a list of SSE items,
//// encode them to a wire-ready byte string, then decode back.
////
////    cd examples/quick_start
////    gleam run

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import ssevents
import ssevents/event.{Comment, EventItem}

pub fn main() {
  let items = [
    ssevents.comment("stream opened"),
    ssevents.named("job.started", "build #42")
      |> ssevents.id("cursor-1")
      |> ssevents.retry(5000)
      |> ssevents.event_item,
    ssevents.named("job.progress", "step 1/3\nrunning lints")
      |> ssevents.id("cursor-2")
      |> ssevents.event_item,
    ssevents.heartbeat(),
  ]

  let body = ssevents.encode_items_bytes(items)
  io.println(
    "wrote " <> int.to_string(bit_array.byte_size(body)) <> " bytes of SSE",
  )

  let assert Ok(decoded) = ssevents.decode_bytes(body)
  io.println("decoded " <> int.to_string(list.length(decoded)) <> " items:")
  list.each(decoded, describe)
}

fn describe(item: ssevents.Item) -> Nil {
  case item {
    EventItem(event) -> {
      let name = case ssevents.name_of(event) {
        Some(n) -> n
        None -> "(message)"
      }
      let id = case ssevents.id_of(event) {
        Some(i) -> ", id=" <> i
        None -> ""
      }
      let retry = case ssevents.retry_of(event) {
        Some(r) -> ", retry=" <> int.to_string(r) <> "ms"
        None -> ""
      }
      io.println(
        "- event " <> name <> id <> retry <> ": " <> ssevents.data_of(event),
      )
    }
    Comment(text) -> io.println("- comment: " <> text)
  }
}
