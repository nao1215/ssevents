//// Drive the incremental decoder with a real-world-shaped chunk
//// sequence and track the reconnect metadata (`Last-Event-ID`,
//// `retry`) that a client should remember across reconnects.
////
////    cd examples/streaming_consume
////    gleam run
////
//// In production code, the chunks would come from your HTTP client of
//// choice (e.g. an `httpc` / `gleam_fetch` body stream on the BEAM, or
//// a `ReadableStream` reader on the JavaScript target). The decoder
//// itself is runtime-agnostic.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import ssevents
import ssevents/event.{Comment, EventItem}

pub fn main() {
  let chunks = wire_chunks()

  io.println(
    "feeding " <> int.to_string(list.length(chunks)) <> " chunks of input",
  )

  let assert Ok(#(state, items)) = drain(ssevents.new_decoder(), chunks, [])
  let assert Ok(trailing) = ssevents.finish(state)
  let all_items = list.append(items, trailing)

  io.println("\n# Items emitted")
  list.each(all_items, describe)

  io.println("\n# Reconnect metadata after the stream")
  let reconnect =
    list.fold(all_items, ssevents.new_reconnect_state(), fn(acc, item) {
      ssevents.update_reconnect(acc, item)
    })

  case ssevents.last_event_id(reconnect) {
    Some(id) -> io.println("- last event id: " <> id)
    None -> io.println("- last event id: (none)")
  }
  case ssevents.retry_interval(reconnect) {
    Some(ms) -> io.println("- retry interval: " <> int.to_string(ms) <> "ms")
    None -> io.println("- retry interval: (none — keep client default)")
  }
  case ssevents.last_event_id_header(reconnect) {
    Some(#(header, value)) ->
      io.println("- send on reconnect: " <> header <> ": " <> value)
    None -> io.println("- send on reconnect: (no header — first connect)")
  }
}

fn drain(
  state: ssevents.DecodeState,
  chunks: List(BitArray),
  emitted_rev: List(ssevents.Item),
) -> Result(#(ssevents.DecodeState, List(ssevents.Item)), ssevents.SseError) {
  case chunks {
    [] -> Ok(#(state, list.reverse(emitted_rev)))
    [chunk, ..rest] ->
      case ssevents.push(state, chunk) {
        Error(error) -> Error(error)
        Ok(#(next_state, items)) ->
          drain(
            next_state,
            rest,
            list.reverse(items) |> list.append(emitted_rev),
          )
      }
  }
}

/// A handcrafted byte stream that mimics what an HTTP client would
/// actually pull from a `text/event-stream` response: a leading UTF-8
/// BOM, an event split across two reads, a multi-line `data` field,
/// and a heartbeat comment.
fn wire_chunks() -> List(BitArray) {
  [
    <<0xEF, 0xBB, 0xBF>>,
    <<"retry: 5000\n":utf8>>,
    <<"id: cursor-1\nevent: job.s":utf8>>,
    <<"tarted\ndata: build #42\n\n":utf8>>,
    <<": heartbeat\n":utf8>>,
    <<"id: cursor-2\nevent: job.progress\ndata: step 1/3\ndata: running":utf8>>,
    <<" lints\n\n":utf8>>,
  ]
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
      io.println("- event " <> name <> id <> ": " <> describe_data(event))
    }
    Comment(text) -> io.println("- comment: " <> text)
  }
}

fn describe_data(event: ssevents.Event) -> String {
  let data = ssevents.data_of(event)
  case bit_array.byte_size(bit_array.from_string(data)) > 64 {
    True ->
      "("
      <> int.to_string(bit_array.byte_size(bit_array.from_string(data)))
      <> " bytes)"
    False -> data
  }
}
