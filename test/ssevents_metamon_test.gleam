//// metamon property tests for the ssevents encode → decode round-trip
//// and the event constructors and accessors. Pin the algebraic
//// invariants the wire-format pipeline is documented to hold so a
//// future encoder / decoder change surfaces a regression here
//// instead of cascading into integration tests.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import metamon
import metamon/generator
import ssevents.{CommentItem, EventItem}
import support

fn decode(text: String) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(<<text:utf8>>, ssevents.default_limits)
}

// ---------- Generators ----------

fn safe_text_generator() -> generator.Generator(String) {
  // Restrict to alphanumeric so the encode → decode round-trip is
  // unambiguous: CR, LF and NUL are removed from names and ids when the
  // event is built (#39), which other tests pin.
  generator.string(
    of: generator.Alphanumeric,
    length: generator.range(from: 0, to: 12),
  )
  |> generator.no_edges
}

fn safe_non_empty_text_generator() -> generator.Generator(String) {
  generator.string(
    of: generator.Alphanumeric,
    length: generator.range(from: 1, to: 8),
  )
  |> generator.no_edges
}

// ---------- event constructors / accessors round-trip ----------

pub fn new_data_round_trips_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    assert #(
        ssevents.data_of(evt),
        ssevents.name_of(evt),
        ssevents.id_of(evt),
        ssevents.retry_of(evt),
      )
      == #(data, None, None, None)
  })
}

pub fn named_sets_name_and_data_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_non_empty_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(name, data) = pair
      let evt = support.named(name, data)
      assert #(ssevents.name_of(evt), ssevents.data_of(evt))
        == #(Some(name), data)
    },
  )
}

pub fn id_setter_round_trips_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_text_generator(), safe_non_empty_text_generator()),
    fn(pair) {
      let #(data, id) = pair
      let evt = ssevents.new(data) |> support.id(id)
      assert ssevents.id_of(evt) == Some(id)
    },
  )
}

// ---------- encoder → decoder round-trip ----------

pub fn encode_then_decode_preserves_data_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    let wire = ssevents.encode(evt)
    let assert Ok([EventItem(decoded)]) = decode(wire)
    assert ssevents.data_of(decoded) == data
  })
}

pub fn encode_then_decode_rewrites_only_line_terminators_test() -> Nil {
  // Data made of text and every SSE line terminator (CR, LF, CRLF, and
  // CR CR LF, which must split into two breaks) round-trips to the same
  // text with each terminator rewritten to LF: no line is lost or added.
  let piece = generator.element_of(["a", "bc", "\n", "\r", "\r\n", "\r\r\n"])
  metamon.forall(
    generator.list_of(piece, generator.range(from: 0, to: 12))
      |> generator.no_edges,
    fn(pieces) {
      let data = string.concat(pieces)
      let expected = to_lf(data)
      let assert Ok([EventItem(decoded)]) =
        decode(ssevents.encode(ssevents.new(data)))
      assert ssevents.data_of(decoded) == expected
    },
  )
}

/// CRLF and lone CR to LF, by code point, independently of how the
/// target's `string.replace` treats the CRLF grapheme.
fn to_lf(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
  |> lf_codepoints([])
}

fn lf_codepoints(codes: List(Int), acc: List(Int)) -> String {
  case codes {
    [] ->
      acc
      |> list.reverse
      |> list.filter_map(string.utf_codepoint)
      |> string.from_utf_codepoints
    [13, 10, ..rest] | [13, ..rest] -> lf_codepoints(rest, [10, ..acc])
    [code, ..rest] -> lf_codepoints(rest, [code, ..acc])
  }
}

pub fn encode_then_decode_preserves_named_event_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_non_empty_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(name, data) = pair
      let evt = support.named(name, data)
      let wire = ssevents.encode(evt)
      let assert Ok([EventItem(decoded)]) = decode(wire)
      assert #(ssevents.name_of(decoded), ssevents.data_of(decoded))
        == #(Some(name), data)
    },
  )
}

pub fn encode_then_decode_preserves_id_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_text_generator(), safe_non_empty_text_generator()),
    fn(pair) {
      let #(data, id) = pair
      let evt = ssevents.new(data) |> support.id(id)
      let wire = ssevents.encode(evt)
      let assert Ok([EventItem(decoded)]) = decode(wire)
      assert ssevents.id_of(decoded) == Some(id)
    },
  )
}

pub fn encode_then_decode_preserves_retry_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      safe_text_generator(),
      generator.int(generator.range(from: 0, to: 100_000)),
    ),
    fn(pair) {
      let #(data, retry_ms) = pair
      let evt = ssevents.new(data) |> ssevents.retry(retry_ms)
      let wire = ssevents.encode(evt)
      let assert Ok([EventItem(decoded)]) = decode(wire)
      assert ssevents.retry_of(decoded) == Some(retry_ms)
    },
  )
}

pub fn encode_items_round_trip_count_test() -> Nil {
  metamon.forall(
    generator.list_of(safe_text_generator(), generator.range(from: 0, to: 5)),
    fn(data_list) {
      let items =
        list.map(data_list, fn(data) { EventItem(ssevents.new(data)) })
      let wire = ssevents.encode_items(items)
      let assert Ok(decoded_items) = decode(wire)
      assert list.length(decoded_items) == list.length(items)
    },
  )
}

pub fn comment_round_trips_through_encode_decode_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(text) {
    let comment_item = support.comment(text)
    let wire = ssevents.encode_items([comment_item])
    let assert Ok([CommentItem(_)]) = decode(wire)
    Nil
  })
}

pub fn empty_input_decodes_to_empty_list_test() -> Nil {
  let assert Ok(items) = decode("")
  assert items == []
}

// ---------- encode wire shape ----------

pub fn encoded_event_ends_with_blank_line_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    let wire = ssevents.encode(evt)
    // Per the SSE wire-format spec, every event terminates with a
    // blank line (`\n\n` for LF or `\r\n\r\n` for CRLF). The
    // default line ending is LF.
    assert string.ends_with(wire, "\n\n")
  })
}

pub fn encoded_event_contains_data_field_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    let wire = ssevents.encode(evt)
    assert string.contains(wire, "data: " <> data)
  })
}

// ---------- long data lines ----------

/// Limits wide enough for every line and event the long-data generator
/// builds, so only the encoder decides whether the data survives.
const wide_limits =
  ssevents.Limits(
    ..ssevents.default_limits,
    max_line_bytes: 1_000_000,
    max_event_bytes: 1_000_000,
  )

fn long_data_generator() -> generator.Generator(String) {
  // Runs around the old split threshold of 8000 bytes, in one-, two-,
  // three- and four-byte characters and a seven-code-point grapheme,
  // mixed with every line terminator.
  let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
  let piece =
    generator.element_of([
      "a",
      "\n",
      "\r",
      "\r\n",
      string.repeat("x", 4093),
      string.repeat("x", 8187),
      string.repeat("é", 2001),
      string.repeat("あ", 2731),
      string.repeat("🦊", 2001),
      string.repeat(family, 401),
    ])
  generator.list_of(piece, generator.range(from: 0, to: 6))
  |> generator.map(string.concat)
  |> generator.no_edges
}

fn data_lines(wire: String) -> Int {
  wire
  |> string.split("\n")
  |> list.count(fn(line) { string.starts_with(line, "data") })
}

pub fn encode_then_decode_preserves_long_data_test() -> Nil {
  // The encoder used to split a line longer than 8000 bytes into lines
  // of 2000 code points, and the decoder joins `data` lines with LF, so
  // the client got an LF the server never sent.
  metamon.forall(long_data_generator(), fn(data) {
    let wire = ssevents.encode(ssevents.new(data))
    assert ssevents.decode(<<wire:utf8>>, wide_limits)
      == Ok([EventItem(ssevents.new(to_lf(data)))])
  })
}

pub fn encode_writes_one_data_line_per_line_of_data_test() -> Nil {
  metamon.forall(long_data_generator(), fn(data) {
    let lines = to_lf(data) |> string.split("\n") |> list.length
    assert data_lines(ssevents.encode(ssevents.new(data))) == lines
  })
}

pub fn pushed_long_data_round_trips_test() -> Nil {
  // The same wire read in chunks, which can end inside a long line or a
  // character.
  metamon.forall(
    generator.tuple2(
      long_data_generator(),
      generator.int(generator.range(from: 1, to: 9000)),
    ),
    fn(input) {
      let #(data, size) = input
      let wire = <<ssevents.encode(ssevents.new(data)):utf8>>
      assert pushed(ssevents.new_decoder(wide_limits), wire, size, [])
        == Ok([EventItem(ssevents.new(to_lf(data)))])
    },
  )
}

fn pushed(
  state: ssevents.DecodeState,
  rest: BitArray,
  size: Int,
  acc: List(ssevents.Item),
) -> Result(List(ssevents.Item), ssevents.SseError) {
  let total = bit_array.byte_size(rest)
  case total {
    0 -> Ok(list.append(acc, ssevents.finish(state)))
    _ -> {
      let take = int.min(size, total)
      let assert Ok(chunk) = bit_array.slice(rest, at: 0, take: take)
      let assert Ok(tail) = bit_array.slice(rest, at: take, take: total - take)
      case ssevents.push(state, chunk) {
        Ok(#(state, items)) ->
          pushed(state, tail, size, list.append(acc, items))
        Error(error) -> Error(error)
      }
    }
  }
}
