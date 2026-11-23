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

fn data_without_splits(items: List(ssevents.Item)) -> List(String) {
  // The encoder splits long `data:` lines and the decoder joins them with
  // LF (#88), so the inserted LFs are removed before comparing.
  list.map(items, fn(item) {
    case item {
      EventItem(event) ->
        ssevents.data_of(event) |> string.replace(each: "\n", with: "")
      _ -> ""
    }
  })
}

pub fn decode_large_event_with_relaxed_limit_test() {
  let long_data = string.repeat("x", 100_000)
  let wire = ssevents.encode(ssevents.new(long_data))
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 200_000)
  let assert Ok(items) = ssevents.decode(<<wire:utf8>>, limits)
  data_without_splits(items) |> should.equal([long_data])
}

pub fn decode_default_limit_still_rejects_oversize_test() {
  let wire = ssevents.encode(ssevents.new(string.repeat("x", 100_000)))
  ssevents.decode(<<wire:utf8>>, ssevents.default_limits)
  |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_unreachable_under_default_cap_test() {
  // The error ends decoding; later events are not returned.
  let oversize = string.repeat("x", 100_000)
  let wire =
    ssevents.encode_items([
      EventItem(ssevents.new(oversize)),
      EventItem(ssevents.new("late")),
    ])
  ssevents.decode(<<wire:utf8>>, ssevents.default_limits)
  |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_reachable_with_raised_cap_test() {
  let oversize = string.repeat("x", 100_000)
  let wire =
    ssevents.encode_items([
      EventItem(ssevents.new(oversize)),
      EventItem(ssevents.new("late")),
    ])
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 200_000)
  let assert Ok(items) = ssevents.decode(<<wire:utf8>>, limits)
  data_without_splits(items) |> should.equal([oversize, "late"])
}

pub fn default_max_event_bytes_is_65536_test() {
  ssevents.default_limits.max_event_bytes |> should.equal(65_536)
}
