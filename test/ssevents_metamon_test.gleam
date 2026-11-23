//// metamon property tests for the ssevents encode → decode round-trip
//// and the event constructors and accessors. Pin the algebraic
//// invariants the wire-format pipeline is documented to hold so a
//// future encoder / decoder change surfaces a regression here
//// instead of cascading into integration tests.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
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
  generator.string_alphanumeric(range.constant(0, 12))
  |> generator.no_edges
}

fn safe_non_empty_text_generator() -> generator.Generator(String) {
  generator.string_alphanumeric(range.constant(1, 8))
  |> generator.no_edges
}

// ---------- event constructors / accessors round-trip ----------

pub fn new_data_round_trips_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    ssevents.data_of(evt) == data
    && ssevents.name_of(evt) == None
    && ssevents.id_of(evt) == None
    && ssevents.retry_of(evt) == None
  })
}

pub fn named_sets_name_and_data_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_non_empty_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(name, data) = pair
      let evt = support.named(name, data)
      ssevents.name_of(evt) == Some(name) && ssevents.data_of(evt) == data
    },
  )
}

pub fn id_setter_round_trips_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_text_generator(), safe_non_empty_text_generator()),
    fn(pair) {
      let #(data, id) = pair
      let evt = ssevents.new(data) |> support.id(id)
      ssevents.id_of(evt) == Some(id)
    },
  )
}

// ---------- encoder → decoder round-trip ----------

pub fn encode_then_decode_preserves_data_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    let wire = ssevents.encode(evt)
    let assert Ok(items) = decode(wire)
    case items {
      [item] ->
        case item {
          EventItem(decoded) -> ssevents.data_of(decoded) == data
          _ -> False
        }
      _ -> False
    }
  })
}

pub fn encode_then_decode_rewrites_only_line_terminators_test() -> Nil {
  // Data made of text and every SSE line terminator (CR, LF, CRLF, and
  // CR CR LF, which must split into two breaks) round-trips to the same
  // text with each terminator rewritten to LF: no line is lost or added.
  let piece = generator.element_of(["a", "bc", "\n", "\r", "\r\n", "\r\r\n"])
  metamon.forall(
    generator.list_of(piece, range.constant(0, 12)) |> generator.no_edges,
    fn(pieces) {
      let data = string.concat(pieces)
      let expected = to_lf(data)
      let assert Ok(items) = decode(ssevents.encode(ssevents.new(data)))
      case items {
        [item] ->
          case item {
            EventItem(decoded) -> ssevents.data_of(decoded) == expected
            _ -> False
          }
        _ -> False
      }
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
      let assert Ok(items) = decode(wire)
      case items {
        [item] ->
          case item {
            EventItem(decoded) ->
              ssevents.name_of(decoded) == Some(name)
              && ssevents.data_of(decoded) == data
            _ -> False
          }
        _ -> False
      }
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
      let assert Ok(items) = decode(wire)
      case items {
        [item] ->
          case item {
            EventItem(decoded) -> ssevents.id_of(decoded) == Some(id)
            _ -> False
          }
        _ -> False
      }
    },
  )
}

pub fn encode_then_decode_preserves_retry_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      safe_text_generator(),
      generator.int(range.constant(0, 100_000)),
    ),
    fn(pair) {
      let #(data, retry_ms) = pair
      let evt = ssevents.new(data) |> ssevents.retry(retry_ms)
      let wire = ssevents.encode(evt)
      let assert Ok(items) = decode(wire)
      case items {
        [item] ->
          case item {
            EventItem(decoded) -> ssevents.retry_of(decoded) == Some(retry_ms)
            _ -> False
          }
        _ -> False
      }
    },
  )
}

pub fn encode_items_round_trip_count_test() -> Nil {
  metamon.forall(
    generator.list_of(safe_text_generator(), range.constant(0, 5)),
    fn(data_list) {
      let items =
        list.map(data_list, fn(data) { EventItem(ssevents.new(data)) })
      let wire = ssevents.encode_items(items)
      let assert Ok(decoded_items) = decode(wire)
      list.length(decoded_items) == list.length(items)
    },
  )
}

pub fn comment_round_trips_through_encode_decode_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(text) {
    let comment_item = support.comment(text)
    let wire = ssevents.encode_items([comment_item])
    let assert Ok(items) = decode(wire)
    case items {
      [CommentItem(_)] -> True
      _ -> False
    }
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
    string.ends_with(wire, "\n\n")
  })
}

pub fn encoded_event_contains_data_field_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(data) {
    let evt = ssevents.new(data)
    let wire = ssevents.encode(evt)
    string.contains(wire, "data: " <> data)
  })
}
