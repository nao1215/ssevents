//// Differential tests between the one-shot decoder (`decode_bytes_with_limits`)
//// and the incremental one (`push` / `finish`) on random wire text that the
//// encoder would never produce: mixed LF / CRLF / lone CR line endings,
//// unknown fields, fields without a colon, bad retry values and comments.
//// Every limit is set one below, at and one above the size the input
//// needs, so both decoders must draw the line at the same byte however
//// the input is cut into chunks.

import gleam/bit_array
import gleam/list
import gleam/string
import metamon
import metamon/generator.{type Generator}
import metamon/generator/range
import ssevents

fn line_gen() -> Generator(String) {
  let value =
    generator.list_of(
      generator.element_of(["a", "Z", "9", " ", ":", "\u{00E9}", "\u{0000}"]),
      range.constant(0, 6),
    )
    |> generator.map(string.concat)
  generator.one_of([
    generator.map(value, fn(v) { "data: " <> v }),
    generator.map(value, fn(v) { "data:" <> v }),
    generator.return("data"),
    generator.map(value, fn(v) { "event: " <> v }),
    generator.map(value, fn(v) { "id: " <> v }),
    generator.element_of([
      "retry: 10",
      "retry: 99999999999",
      "retry: x1",
      "retry:",
    ]),
    generator.map(value, fn(v) { ":" <> v }),
    generator.map(value, fn(v) { "other: " <> v }),
    generator.return(""),
  ])
}

fn wire_gen() -> Generator(BitArray) {
  generator.list_of(
    generator.tuple2(line_gen(), generator.element_of(["\n", "\r\n", "\r"])),
    range.constant(0, 12),
  )
  |> generator.map(fn(lines) {
    lines
    |> list.map(fn(l) { l.0 <> l.1 })
    |> string.concat
    |> bit_array.from_string
  })
}

fn chunks(bytes: BitArray, sizes: List(Int)) -> List(BitArray) {
  chunk_loop(bytes, sizes, sizes, [])
}

fn chunk_loop(
  bytes: BitArray,
  sizes: List(Int),
  all: List(Int),
  acc: List(BitArray),
) -> List(BitArray) {
  let total = bit_array.byte_size(bytes)
  case total, sizes {
    0, _ -> list.reverse(acc)
    _, [] -> chunk_loop(bytes, all, all, acc)
    _, [n, ..rest] -> {
      let take = case n > total {
        True -> total
        False -> n
      }
      let assert Ok(head) = bit_array.slice(bytes, 0, take)
      let assert Ok(tail) = bit_array.slice(bytes, take, total - take)
      chunk_loop(tail, rest, all, [head, ..acc])
    }
  }
}

fn incremental(
  pieces: List(BitArray),
  limits: ssevents.Limits,
) -> Result(List(ssevents.Item), ssevents.SseError) {
  push_all(ssevents.new_decoder_with_limits(limits), pieces, [])
}

fn push_all(
  state: ssevents.DecodeState,
  pieces: List(BitArray),
  acc: List(List(ssevents.Item)),
) -> Result(List(ssevents.Item), ssevents.SseError) {
  case pieces {
    [] ->
      case ssevents.finish(state) {
        Ok(last) -> Ok(list.flatten(list.reverse([last, ..acc])))
        Error(e) -> Error(e)
      }
    [piece, ..rest] ->
      case ssevents.push(state, piece) {
        Ok(#(next, items)) -> push_all(next, rest, [items, ..acc])
        Error(e) -> Error(e)
      }
  }
}

fn sizes_gen() -> Generator(List(Int)) {
  generator.list_of(generator.int(range.constant(1, 9)), range.constant(1, 5))
}

pub fn incremental_matches_one_shot_with_default_limits_test() -> Nil {
  metamon.forall(generator.tuple2(wire_gen(), sizes_gen()), fn(input) {
    let #(wire, sizes) = input
    let limits = ssevents.default_limits()
    incremental(chunks(wire, sizes), limits)
    == ssevents.decode_bytes_with_limits(wire, limits: limits)
  })
}

/// The longest line, the total bytes and the number of `data` lines in
/// `wire`: upper bounds of what each limit has to allow.
fn needs(wire: BitArray) -> #(Int, Int, Int) {
  let assert Ok(text) = bit_array.to_string(wire)
  let lines =
    text
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")
  let longest =
    list.fold(lines, 1, fn(acc, l) {
      let size = string.byte_size(l)
      case size > acc {
        True -> size
        False -> acc
      }
    })
  let data_lines = list.count(lines, fn(l) { string.starts_with(l, "data") })
  #(longest, bit_array.byte_size(wire), data_lines)
}

pub fn incremental_matches_one_shot_at_limit_boundaries_test() -> Nil {
  metamon.forall(
    generator.tuple3(
      wire_gen(),
      sizes_gen(),
      generator.tuple2(
        generator.element_of(["line", "event", "data", "retry"]),
        generator.int(range.constant(-1, 1)),
      ),
    ),
    boundary_property,
  )
}

fn boundary_property(input: #(BitArray, List(Int), #(String, Int))) -> Bool {
  let #(wire, sizes, #(which, delta)) = input
  let #(longest, total, data_lines) = needs(wire)
  let at = fn(n) {
    case n + delta < 1 {
      True -> 1
      False -> n + delta
    }
  }
  let defaults = ssevents.default_limits()
  let #(line, event, data, retry) = #(
    ssevents.max_line_bytes(defaults),
    ssevents.max_event_bytes(defaults),
    ssevents.max_data_lines(defaults),
    ssevents.max_retry_value(defaults),
  )
  let limits = case which {
    "line" -> ssevents.new_limits(at(longest), event, data, retry)
    "event" -> ssevents.new_limits(line, at(total), data, retry)
    "data" -> ssevents.new_limits(line, event, at(data_lines), retry)
    _ -> ssevents.new_limits(line, event, data, at(10))
  }
  incremental(chunks(wire, sizes), limits)
  == ssevents.decode_bytes_with_limits(wire, limits: limits)
}
