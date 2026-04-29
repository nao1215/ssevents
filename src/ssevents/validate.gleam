//// Explicit validation helpers for domain values.

import gleam/bit_array
import gleam/int
import ssevents/error.{type SseError, EventTooLarge, InvalidField, InvalidRetry}
import ssevents/event

pub fn validate_event_name(name: String) -> Result(String, SseError) {
  case contains_forbidden_text_byte(name) {
    True -> Error(InvalidField("event"))
    False -> Ok(name)
  }
}

pub fn validate_id(id: String) -> Result(String, SseError) {
  case contains_forbidden_text_byte(id) {
    True -> Error(InvalidField("id"))
    False -> Ok(id)
  }
}

pub fn validate_retry(milliseconds: Int) -> Result(Int, SseError) {
  case milliseconds < 0 {
    True -> Error(InvalidRetry(int_to_string(milliseconds)))
    False -> Ok(milliseconds)
  }
}

pub fn max_data_bytes(
  event: event.Event,
  max max: Int,
) -> Result(event.Event, SseError) {
  case max < 0 {
    True -> panic as "max must be >= 0"
    False -> Nil
  }

  let data_size =
    event.data_of(event) |> bit_array.from_string |> bit_array.byte_size
  case data_size > max {
    True -> Error(EventTooLarge(max))
    False -> Ok(event)
  }
}

fn contains_forbidden_text_byte(input: String) -> Bool {
  contains_forbidden_bytes(bit_array.from_string(input))
}

fn contains_forbidden_bytes(input: BitArray) -> Bool {
  case input {
    <<>> -> False
    <<0, _rest:bytes>> -> True
    <<10, _rest:bytes>> -> True
    <<13, _rest:bytes>> -> True
    <<_, rest:bytes>> -> contains_forbidden_bytes(rest)
    _ -> True
  }
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
