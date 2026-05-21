//// Regression coverage for #95.
////
//// Pre-#95 the decoder failed the whole stream with
//// `Error(InvalidRetry(_))` whenever a `retry:` value exceeded the
//// 24h cap (`limit.default_max_retry_value`). That was asymmetric
//// with the encoder's `retry_clamp/2`, which silently dropped such
//// values to `None`, and a single hostile `retry: 99999999999999`
//// could knock out the rest of the stream.
////
//// Post-#95 the decoder is lenient by default — above-cap values
//// drop to `None` and the surrounding event still dispatches. The
//// strict (cap-overrun = `Error`) posture remains available through
//// `limit.with_strict_retry_cap(_, True)`.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents
import ssevents/error.{InvalidRetry}

// === Lenient default — retry over the cap silently drops ===

pub fn decode_with_retry_over_24h_still_returns_event_test() {
  let assert Ok([item]) = ssevents.decode("retry: 86400001\ndata: x\n\n")
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.data_of(ev) |> should.equal("x")
  // 24h + 1ms is above `default_max_retry_value` (86_400_000); the
  // lenient default drops the retry field to `None` rather than
  // failing the whole stream.
  ssevents.retry_of(ev) |> should.equal(None)
}

pub fn decode_with_huge_retry_still_returns_event_test() {
  let assert Ok([item]) = ssevents.decode("retry: 99999999999999\ndata: x\n\n")
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.data_of(ev) |> should.equal("x")
  ssevents.retry_of(ev) |> should.equal(None)
}

pub fn decode_multiple_events_with_one_bad_retry_test() {
  // The original repro: an early event has a 1e13-ms retry. Pre-#95
  // the rest of the stream was unreachable; post-#95 the first
  // event's retry drops to `None` and the later events still
  // dispatch.
  let wire = "retry: 99999999999999\ndata: a\n\ndata: b\n\ndata: c\n\n"
  let assert Ok(items) = ssevents.decode(wire)
  list.length(items) |> should.equal(3)
  // Spot-check that the data payloads survived the cap-overrun.
  let datas =
    items
    |> list.filter_map(fn(item) {
      case ssevents.event_of_item(item) {
        Some(ev) -> Ok(ssevents.data_of(ev))
        None -> Error(Nil)
      }
    })
  datas |> should.equal(["a", "b", "c"])
}

// === Regression for the still-working baseline ===

pub fn decode_retry_at_24h_cap_test() {
  let assert Ok([item]) = ssevents.decode("retry: 86400000\ndata: x\n\n")
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.retry_of(ev) |> should.equal(Some(86_400_000))
}

pub fn decode_normal_retry_test() {
  let assert Ok([item]) = ssevents.decode("retry: 5000\ndata: x\n\n")
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.retry_of(ev) |> should.equal(Some(5000))
}

pub fn encode_decode_retry_clamp_symmetry_test() {
  // Encoder side: `retry_clamp(_, 1e13)` silently maps to `None`
  // (see `event.sanitize_retry`). Post-#95 the decoder mirrors that
  // posture, so the two ends of the wire agree.
  let event = ssevents.new("x") |> ssevents.retry_clamp(99_999_999_999_999)
  ssevents.retry_of(event) |> should.equal(None)
}

// === Strict opt-in still surfaces the cap overrun as an error ===

pub fn decode_with_strict_retry_cap_above_limit_errors_test() {
  let limits = ssevents.default_limits() |> ssevents.with_strict_retry_cap(True)
  ssevents.decode_with_limits(
    "retry: 99999999999999\ndata: x\n\n",
    limits: limits,
  )
  |> should.equal(Error(InvalidRetry("99999999999999")))
}

pub fn decode_with_strict_retry_cap_at_cap_still_ok_test() {
  // Strict mode only flips the *over*-the-cap branch — the at-cap
  // value is still accepted.
  let limits = ssevents.default_limits() |> ssevents.with_strict_retry_cap(True)
  let assert Ok([item]) =
    ssevents.decode_with_limits("retry: 86400000\ndata: x\n\n", limits: limits)
  let assert Some(ev) = ssevents.event_of_item(item)
  ssevents.retry_of(ev) |> should.equal(Some(86_400_000))
}

pub fn default_limits_strict_retry_cap_is_false_test() {
  ssevents.default_limits() |> ssevents.strict_retry_cap |> should.equal(False)
}

pub fn with_strict_retry_cap_true_flips_flag_test() {
  ssevents.default_limits()
  |> ssevents.with_strict_retry_cap(True)
  |> ssevents.strict_retry_cap
  |> should.equal(True)
}
