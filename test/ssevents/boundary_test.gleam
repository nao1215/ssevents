//// Boundary values of the limits and validators: each check is exercised
//// exactly at its threshold and one step past it, where an off-by-one
//// comparison would change the answer. Both decoders share these checks,
//// so the differential test in limits_differential_test.gleam cannot see
//// a shift that moves them together.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents
import ssevents/error.{EventTooLarge}
import ssevents/event.{EventItem}
import ssevents/limit
import ssevents/validate

fn limits_with_event_bytes(max: Int) -> ssevents.Limits {
  ssevents.new_limits(
    max_line_bytes: 100,
    max_event_bytes: max,
    max_data_lines: 10,
    max_retry_value: 1000,
  )
}

pub fn event_of_exactly_max_event_bytes_is_accepted_test() {
  // "data: abcd" is 10 bytes; the blank line adds none.
  let wire = "data: abcd\n\n"
  let assert Ok([EventItem(decoded)]) =
    ssevents.decode_with_limits(wire, limits: limits_with_event_bytes(10))
  ssevents.data_of(decoded) |> should.equal("abcd")
  ssevents.decode_with_limits(wire, limits: limits_with_event_bytes(9))
  |> should.equal(Error(EventTooLarge(9)))
}

pub fn max_data_bytes_allows_exactly_max_test() {
  let four = ssevents.new("abcd")
  ssevents.max_data_bytes(four, 4) |> should.equal(Ok(four))
  ssevents.max_data_bytes(four, 3) |> should.equal(Error(EventTooLarge(3)))
  let empty = ssevents.new("")
  ssevents.max_data_bytes(empty, 0) |> should.equal(Ok(empty))
  validate.max_data_bytes_checked(empty, max: 0)
  |> should.equal(Ok(Ok(empty)))
}

pub fn zero_and_one_are_valid_limit_values_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 1,
      max_event_bytes: 1,
      max_data_lines: 1,
      max_retry_value: 0,
    )
  ssevents.max_retry_value(limits) |> should.equal(0)
  ssevents.default_limits()
  |> limit.with_max_event_size(1)
  |> ssevents.max_event_bytes
  |> should.equal(1)
}

pub fn zero_retry_is_kept_test() {
  ssevents.from_parts(event_name: None, data: "x", id: None, retry: Some(0))
  |> ssevents.retry_of
  |> should.equal(Some(0))
  ssevents.new("x")
  |> ssevents.retry_clamp(0)
  |> ssevents.retry_of
  |> should.equal(Some(0))
}

pub fn empty_retry_value_is_ignored_test() {
  // WHATWG SSE §9.2.6: a retry value that is not all ASCII digits (the
  // empty string included) is ignored.
  let assert Ok([EventItem(decoded)]) = ssevents.decode("retry:\ndata: x\n\n")
  ssevents.retry_of(decoded) |> should.equal(None)
}

pub fn forbidden_bytes_are_rejected_in_names_and_ids_test() {
  ["a\nb", "a\rb", "a\u{0000}b"]
  |> list.each(fn(bad) {
    ssevents.validate_event_name(bad) |> should.be_error
    ssevents.validate_id(bad) |> should.be_error
  })
  ssevents.validate_event_name("ab") |> should.equal(Ok("ab"))
}
