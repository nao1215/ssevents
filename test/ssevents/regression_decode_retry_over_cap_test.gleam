//// Regression coverage for #95.
////
//// A `retry:` value above `max_retry_value` used to fail the whole stream
//// with `InvalidRetry(_)`, so one hostile `retry: 99999999999999` hid
//// every later event. The decoder now ignores such a value and still
//// returns the event, as `retry` does on the encoding side.

import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{EventItem}

fn decode(text: String) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(<<text:utf8>>, ssevents.default_limits)
}

pub fn decode_with_retry_over_24h_still_returns_event_test() {
  let assert Ok([EventItem(event)]) = decode("retry: 86400001\ndata: x\n\n")
  ssevents.data_of(event) |> should.equal("x")
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn decode_with_huge_retry_still_returns_event_test() {
  let assert Ok([EventItem(event)]) =
    decode("retry: 99999999999999999999999\ndata: x\n\n")
  ssevents.data_of(event) |> should.equal("x")
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn decode_multiple_events_with_one_bad_retry_test() {
  decode("retry: 99999999999999\ndata: a\n\ndata: b\n\ndata: c\n\n")
  |> should.equal(
    Ok([
      EventItem(ssevents.new("a")),
      EventItem(ssevents.new("b")),
      EventItem(ssevents.new("c")),
    ]),
  )
}

pub fn decode_retry_at_24h_cap_test() {
  let assert Ok([EventItem(event)]) = decode("retry: 86400000\ndata: x\n\n")
  ssevents.retry_of(event) |> should.equal(Some(86_400_000))
}

pub fn decode_normal_retry_test() {
  let assert Ok([EventItem(event)]) = decode("retry: 5000\ndata: x\n\n")
  ssevents.retry_of(event) |> should.equal(Some(5000))
}

pub fn encode_and_decode_drop_the_same_retry_values_test() {
  ssevents.new("x")
  |> ssevents.retry(99_999_999_999_999)
  |> ssevents.retry_of
  |> should.equal(None)
}
