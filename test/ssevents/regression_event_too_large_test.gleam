//// Regression coverage for #96.
////
//// Pre-#96 `ssevents.decode(wire)` failed the whole stream with a
//// hardcoded `Error(EventTooLarge(65_536))` whenever a single event
//// exceeded 65_536 bytes. The encoder side never rejected an event
//// for sheer size, so a 100 KB event produced by the package's own
//// `encode_item` was unreachable on the decode side and could knock
//// out every later event in the same wire.
////
//// Post-#96 the 65_536-byte cap remains the *default* (memory-bound
//// safety net for untrusted input), but callers can raise it through
//// `limit.with_max_event_size/2` and pipe the limits through
//// `decode_with_limits`.

import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import ssevents
import ssevents/error.{EventTooLarge}

// === Raised cap — `decode_with_limits` lets a 100 KB event round-trip ===

pub fn decode_large_event_with_relaxed_limit_test() {
  // The repro from #96: a 100 KB payload encoded by `encode_item` is
  // unreachable through `decode/1` under the default 65_536-byte cap.
  // With `with_max_event_size(200_000)` the wire round-trips. The
  // encoder chunks long `data:` payloads into ≤ 2000-codepoint lines
  // (#88), and WHATWG SSE §9.2.6 joins them back with LF on dispatch,
  // so the decoded data carries embedded `\n` separators — strip them
  // before comparing the payload.
  let long_data = string.repeat("x", 100_000)
  let item = ssevents.new(long_data) |> ssevents.event_item
  let wire = ssevents.encode_item(item)
  let lim = ssevents.default_limits() |> ssevents.with_max_event_size(200_000)
  let assert Ok([decoded]) = ssevents.decode_with_limits(wire, limits: lim)
  let assert Some(ev) = ssevents.event_of_item(decoded)
  ev
  |> ssevents.data_of
  |> string.replace(each: "\n", with: "")
  |> should.equal(long_data)
}

pub fn decode_bytes_large_event_with_relaxed_limit_test() {
  // BitArray counterpart of the String round-trip above. Same
  // chunking caveat for the LF separators.
  let long_data = string.repeat("y", 80_000)
  let item = ssevents.new(long_data) |> ssevents.event_item
  let wire = ssevents.encode_item_bytes(item)
  let lim = ssevents.default_limits() |> ssevents.with_max_event_size(150_000)
  let assert Ok([decoded]) =
    ssevents.decode_bytes_with_limits(wire, limits: lim)
  let assert Some(ev) = ssevents.event_of_item(decoded)
  ev
  |> ssevents.data_of
  |> string.replace(each: "\n", with: "")
  |> should.equal(long_data)
}

// === Default behaviour preserved — `decode/1` still rejects oversize ===

pub fn decode_default_limit_still_rejects_oversize_test() {
  // The 65_536-byte ceiling is a memory-bound safety net for
  // untrusted input. `decode/1` keeps it; the override is opt-in.
  let long_data = string.repeat("x", 100_000)
  let item = ssevents.new(long_data) |> ssevents.event_item
  let wire = ssevents.encode_item(item)
  ssevents.decode(wire) |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_unreachable_under_default_cap_test() {
  // Pre-#96 the entire stream failed when an early event was over the
  // hardcoded cap. Document that behaviour: under the default cap the
  // later events are still unreachable. The fix is to raise the cap
  // (see the test below), not to silently skip the offender.
  let oversize = string.repeat("x", 100_000)
  let wire =
    ssevents.encode_items([
      ssevents.new(oversize) |> ssevents.event_item,
      ssevents.new("late") |> ssevents.event_item,
    ])
  ssevents.decode(wire) |> should.equal(Error(EventTooLarge(65_536)))
}

pub fn decode_later_events_reachable_with_raised_cap_test() {
  // Same wire as above, but with a raised cap — both events survive,
  // including every later one that the pre-#96 hardcoded reject would
  // have swallowed. (Strip the `\n` separators the chunking encoder
  // inserts into long `data:` payloads, per #88.)
  let oversize = string.repeat("x", 100_000)
  let wire =
    ssevents.encode_items([
      ssevents.new(oversize) |> ssevents.event_item,
      ssevents.new("late") |> ssevents.event_item,
    ])
  let lim = ssevents.default_limits() |> ssevents.with_max_event_size(200_000)
  let assert Ok(items) = ssevents.decode_with_limits(wire, limits: lim)
  let datas =
    items
    |> list.filter_map(fn(item) {
      case ssevents.event_of_item(item) {
        Some(ev) ->
          Ok(ev |> ssevents.data_of |> string.replace(each: "\n", with: ""))
        _ -> Error(Nil)
      }
    })
  datas |> should.equal([oversize, "late"])
}

// === Existing-behaviour regression — small events unaffected ===

pub fn decode_normal_event_test() {
  let assert Ok([item]) = ssevents.decode("data: hello\n\n")
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.data_of(ev) |> should.equal("hello")
}

// === Setter / getter wiring ===

pub fn default_limits_max_event_size_is_65536_test() {
  ssevents.default_limits()
  |> ssevents.max_event_size
  |> should.equal(65_536)
}

pub fn with_max_event_size_updates_the_cap_test() {
  ssevents.default_limits()
  |> ssevents.with_max_event_size(200_000)
  |> ssevents.max_event_size
  |> should.equal(200_000)
}

pub fn max_event_size_matches_max_event_bytes_test() {
  // The two getters are aliases; raising one moves the other.
  let lim = ssevents.default_limits() |> ssevents.with_max_event_size(123_456)
  lim |> ssevents.max_event_size |> should.equal(123_456)
  lim |> ssevents.max_event_bytes |> should.equal(123_456)
}
