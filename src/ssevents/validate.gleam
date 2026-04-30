//// Explicit validation helpers for domain values.

import gleam/bit_array
import gleam/int
import ssevents/error.{type SseError, EventTooLarge, InvalidField, InvalidRetry}
import ssevents/event
import ssevents/limit.{type LimitConfigError, NonPositiveLimit}

pub fn validate_event_name(name: String) -> Result(String, SseError) {
  validate_no_forbidden_bytes("event", name)
}

pub fn validate_id(id: String) -> Result(String, SseError) {
  validate_no_forbidden_bytes("id", id)
}

fn validate_no_forbidden_bytes(
  field_name: String,
  value: String,
) -> Result(String, SseError) {
  case contains_forbidden_text_byte(value) {
    True -> Error(InvalidField(field_name))
    False -> Ok(value)
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

/// Like `max_data_bytes`, but returns the argument-validation failure
/// as a `LimitConfigError` instead of panicking. Use this when `max`
/// comes from dynamic input.
///
/// The outer `Result` distinguishes argument-validation failures (a
/// configuration error the caller can surface up the chain) from
/// event-validation failures (the inner `Result(event.Event, SseError)`
/// reporting whether the event itself fits the configured limit).
pub fn max_data_bytes_checked(
  event: event.Event,
  max max: Int,
) -> Result(Result(event.Event, SseError), LimitConfigError) {
  case max < 0 {
    True -> Error(NonPositiveLimit("max", max))
    False -> Ok(max_data_bytes(event, max: max))
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
