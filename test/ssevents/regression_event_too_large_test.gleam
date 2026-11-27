//// Regression coverage for #96.
////
//// The decoder fails a stream with `EventTooLarge(65_536)` when one event
//// is larger than `default_limits.max_event_bytes`, while the encoder
//// writes an event of any size. Raising `max_event_bytes` lets such an
//// event, and every event after it, be read back.

import gleam/list
import gleam/string
import gleeunit/should
import ssevents.{EventItem, EventTooLarge}

// 100 lines of 1000 bytes: every line fits `default_limits`, the event
// does not.
fn oversize() -> String {
  list.repeat(string.repeat("x", 1000), 100) |> string.join("\n")
}

const relaxed =
  ssevents.Limits(..ssevents.default_limits, max_event_bytes: 200_000)

pub fn decode_large_event_with_relaxed_limit_test() {
  let wire = ssevents.encode(ssevents.new(oversize()))
  ssevents.decode(<<wire:utf8>>, relaxed)
  |> should.equal(Ok([EventItem(ssevents.new(oversize()))]))
}

pub fn decode_large_single_line_event_with_relaxed_limits_test() {
  // One line of data is written as one line, so it needs a larger
  // `max_line_bytes` too, and then arrives unchanged.
  let long_data = string.repeat("x", 100_000)
  let wire = ssevents.encode(ssevents.new(long_data))
  ssevents.decode(<<wire:utf8>>, relaxed)
  |> should.equal(Error(ssevents.LineTooLong(8192)))
  let limits = ssevents.Limits(..relaxed, max_line_bytes: 100_006)
  ssevents.decode(<<wire:utf8>>, limits)
  |> should.equal(Ok([EventItem(ssevents.new(long_data))]))
}

pub fn decode_default_limit_still_rejects_oversize_test() {
  let wire = ssevents.encode(ssevents.new(oversize()))
  ssevents.decode(<<wire:utf8>>, ssevents.default_limits)
  |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_unreachable_under_default_cap_test() {
  // The error ends decoding; later events are not returned.
  let wire =
    ssevents.encode_items([
      EventItem(ssevents.new(oversize())),
      EventItem(ssevents.new("late")),
    ])
  ssevents.decode(<<wire:utf8>>, ssevents.default_limits)
  |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_reachable_with_raised_cap_test() {
  let wire =
    ssevents.encode_items([
      EventItem(ssevents.new(oversize())),
      EventItem(ssevents.new("late")),
    ])
  ssevents.decode(<<wire:utf8>>, relaxed)
  |> should.equal(
    Ok([EventItem(ssevents.new(oversize())), EventItem(ssevents.new("late"))]),
  )
}

pub fn default_max_event_bytes_is_65536_test() {
  ssevents.default_limits.max_event_bytes |> should.equal(65_536)
}
