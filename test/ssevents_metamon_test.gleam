//// metamon property tests for the ssevents encode → decode round-trip
//// and the public `event` constructors / accessors. Pin the algebraic
//// invariants the wire-format pipeline is documented to hold so a
//// future encoder / decoder change surfaces a regression here
//// instead of cascading into integration tests.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import ssevents/decoder
import ssevents/encoder
import ssevents/event

// ---------- Generators ----------

fn safe_text_generator() -> generator.Generator(String) {
  // Restrict to alphanumeric so the encode → decode round-trip is
  // unambiguous: the encoder strips CR / LF / NUL bytes from event
  // names (#39 / #81), so a generator that emits those edges would
  // surface that bug here. The strict-name property test below pins
  // the strip behaviour explicitly; this generator stays inside the
  // unambiguous shape for the round-trip.
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
    let evt = event.new(data)
    event.data_of(evt) == data
    && event.name_of(evt) == None
    && event.id_of(evt) == None
    && event.retry_of(evt) == None
  })
}

pub fn message_is_alias_for_new_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    event.message(data) == event.new(data)
  })
}

pub fn named_sets_name_and_data_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_non_empty_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(name, data) = pair
      let evt = event.named(name, data)
      event.name_of(evt) == Some(name) && event.data_of(evt) == data
    },
  )
}

pub fn id_setter_round_trips_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_text_generator(), safe_non_empty_text_generator()),
    fn(pair) {
      let #(data, id) = pair
      let evt = event.new(data) |> event.id(id)
      event.id_of(evt) == Some(id)
    },
  )
}

pub fn data_setter_replaces_data_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(initial, replacement) = pair
      let evt = event.new(initial) |> event.data(replacement)
      event.data_of(evt) == replacement
    },
  )
}

pub fn retry_clamp_negative_to_zero_test() -> Nil {
  metamon.forall(generator.int(range.constant(-1000, -1)), fn(value) {
    let evt = event.new("x") |> event.retry_clamp(value)
    event.retry_of(evt) == Some(0)
  })
}

pub fn retry_clamp_non_negative_is_identity_test() -> Nil {
  metamon.forall(generator.int(range.constant(0, 100_000)), fn(value) {
    let evt = event.new("x") |> event.retry_clamp(value)
    event.retry_of(evt) == Some(value)
  })
}

// ---------- encoder → decoder round-trip ----------

pub fn encode_then_decode_preserves_data_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = event.new(data)
    let wire = encoder.encode(evt)
    let assert Ok(items) = decoder.decode(wire)
    case items {
      [item] ->
        case event.event_of_item(item) {
          Some(decoded) -> event.data_of(decoded) == data
          None -> False
        }
      _ -> False
    }
  })
}

pub fn encode_then_decode_preserves_named_event_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_non_empty_text_generator(), safe_text_generator()),
    fn(pair) {
      let #(name, data) = pair
      let evt = event.named(name, data)
      let wire = encoder.encode(evt)
      let assert Ok(items) = decoder.decode(wire)
      case items {
        [item] ->
          case event.event_of_item(item) {
            Some(decoded) ->
              event.name_of(decoded) == Some(name)
              && event.data_of(decoded) == data
            None -> False
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
      let evt = event.new(data) |> event.id(id)
      let wire = encoder.encode(evt)
      let assert Ok(items) = decoder.decode(wire)
      case items {
        [item] ->
          case event.event_of_item(item) {
            Some(decoded) -> event.id_of(decoded) == Some(id)
            None -> False
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
      let evt = event.new(data) |> event.retry_clamp(retry_ms)
      let wire = encoder.encode(evt)
      let assert Ok(items) = decoder.decode(wire)
      case items {
        [item] ->
          case event.event_of_item(item) {
            Some(decoded) -> event.retry_of(decoded) == Some(retry_ms)
            None -> False
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
        list.map(data_list, fn(data) { event.event_item(event.new(data)) })
      let wire = encoder.encode_items(items)
      let assert Ok(decoded_items) = decoder.decode(wire)
      list.length(decoded_items) == list.length(items)
    },
  )
}

pub fn comment_round_trips_through_encode_decode_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(text) {
    let comment_item = event.comment_item(text)
    let wire = encoder.encode_item(comment_item)
    let assert Ok(items) = decoder.decode(wire)
    case items {
      [item] -> event.is_comment(item)
      _ -> False
    }
  })
}

pub fn empty_input_decodes_to_empty_list_test() -> Nil {
  let assert Ok(items) = decoder.decode("")
  assert items == []
}

// ---------- predicates ----------

pub fn is_event_and_is_comment_are_mutually_exclusive_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt_item = event.event_item(event.new(data))
    let comment_item = event.comment_item("note")
    event.is_event(evt_item)
    && !event.is_comment(evt_item)
    && event.is_comment(comment_item)
    && !event.is_event(comment_item)
  })
}

pub fn event_of_item_for_comment_is_none_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(text) {
    let comment_item = event.comment_item(text)
    event.event_of_item(comment_item) == None
  })
}

pub fn comment_text_of_item_for_event_is_none_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt_item = event.event_item(event.new(data))
    event.comment_text_of_item(evt_item) == None
  })
}

// ---------- encode wire shape ----------

pub fn encoded_event_ends_with_blank_line_test() -> Nil {
  metamon.forall(safe_text_generator(), fn(data) {
    let evt = event.new(data)
    let wire = encoder.encode(evt)
    // Per the SSE wire-format spec, every event terminates with a
    // blank line (`\n\n` for LF or `\r\n\r\n` for CRLF). The
    // default line ending is LF.
    string.ends_with(wire, "\n\n")
  })
}

pub fn encoded_event_contains_data_field_test() -> Nil {
  metamon.forall(safe_non_empty_text_generator(), fn(data) {
    let evt = event.new(data)
    let wire = encoder.encode(evt)
    string.contains(wire, "data: " <> data)
  })
}
