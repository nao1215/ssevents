//// Boundary values of the limits and the field rules: each check is
//// exercised exactly at its threshold and one step past it, where an
//// off-by-one comparison would change the answer. Both decoders share
//// these checks, so the differential test in
//// limits_differential_test.gleam cannot see a shift that moves them
//// together.

import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{EventItem, EventTooLarge, LineTooLong, TooManyDataLines}

fn limits_with_event_bytes(max: Int) -> ssevents.Limits {
  ssevents.Limits(
    max_line_bytes: 100,
    max_event_bytes: max,
    max_data_lines: 10,
    max_retry_value: 1000,
  )
}

pub fn event_of_exactly_max_event_bytes_is_accepted_test() {
  // "data: abcd" is 10 bytes; the blank line adds none.
  let wire = <<"data: abcd\n\n":utf8>>
  let assert Ok([EventItem(decoded)]) =
    ssevents.decode(wire, limits_with_event_bytes(10))
  ssevents.data_of(decoded) |> should.equal("abcd")
  ssevents.decode(wire, limits_with_event_bytes(9))
  |> should.equal(Error(EventTooLarge(9)))
}

pub fn comment_lines_do_not_count_towards_max_event_bytes_test() {
  let wire = <<": a long comment line\ndata: abcd\n\n":utf8>>
  ssevents.decode(wire, limits_with_event_bytes(10)) |> should.be_ok
}

pub fn line_of_exactly_max_line_bytes_is_accepted_test() {
  let limits = ssevents.Limits(..ssevents.default_limits, max_line_bytes: 10)
  ssevents.decode(<<"data: abcd\n\n":utf8>>, limits) |> should.be_ok
  ssevents.decode(<<"data: abcde\n\n":utf8>>, limits)
  |> should.equal(Error(LineTooLong(10)))
}

pub fn exactly_max_data_lines_is_accepted_test() {
  let limits = ssevents.Limits(..ssevents.default_limits, max_data_lines: 1)
  ssevents.decode(<<"data: a\n\n":utf8>>, limits) |> should.be_ok
  ssevents.decode(<<"data: a\ndata: b\n\n":utf8>>, limits)
  |> should.equal(Error(TooManyDataLines(1)))
}

pub fn zero_limits_reject_any_matching_input_test() {
  let limits =
    ssevents.Limits(
      max_line_bytes: 0,
      max_event_bytes: 0,
      max_data_lines: 0,
      max_retry_value: 0,
    )
  ssevents.decode(<<"\n\n":utf8>>, limits) |> should.equal(Ok([]))
  ssevents.decode(<<"data\n\n":utf8>>, limits)
  |> should.equal(Error(LineTooLong(0)))
}

pub fn zero_retry_is_kept_test() {
  ssevents.new("x")
  |> ssevents.retry(0)
  |> ssevents.retry_of
  |> should.equal(Some(0))
  let limits = ssevents.Limits(..ssevents.default_limits, max_retry_value: 0)
  let assert Ok([EventItem(decoded)]) =
    ssevents.decode(<<"retry: 0\ndata: x\n\n":utf8>>, limits)
  ssevents.retry_of(decoded) |> should.equal(Some(0))
}

pub fn empty_retry_value_is_ignored_test() {
  // WHATWG SSE §9.2.6: a retry value that is not all ASCII digits (the
  // empty string included) is ignored.
  let assert Ok([EventItem(decoded)]) =
    ssevents.decode(<<"retry:\ndata: x\n\n":utf8>>, ssevents.default_limits)
  ssevents.retry_of(decoded) |> should.equal(None)
}
