import gleam/option.{None, Some}
import gleeunit/should
import ssevents
import ssevents/event

pub fn event_builder_accessors_test() {
  let event =
    ssevents.new("payload")
    |> ssevents.event("job.update")
    |> ssevents.id("job-1")
    |> ssevents.retry(5000)

  ssevents.name_of(event) |> should.equal(Some("job.update"))
  ssevents.data_of(event) |> should.equal("payload")
  ssevents.id_of(event) |> should.equal(Some("job-1"))
  ssevents.retry_of(event) |> should.equal(Some(5000))
}

// Construction-time sanitisation: CR / LF / NUL inside `event` and
// `id` cannot survive the SSE wire format, so they're stripped on
// the way in. Same posture multipartkit/form takes for header values.

pub fn event_setter_strips_lf_test() {
  let event = ssevents.new("payload") |> ssevents.event("foo\nbar")
  ssevents.name_of(event) |> should.equal(Some("foobar"))
}

pub fn event_setter_strips_cr_test() {
  let event = ssevents.new("payload") |> ssevents.event("foo\rbar")
  ssevents.name_of(event) |> should.equal(Some("foobar"))
}

pub fn event_setter_strips_nul_test() {
  let event = ssevents.new("payload") |> ssevents.event("foo\u{0000}bar")
  ssevents.name_of(event) |> should.equal(Some("foobar"))
}

pub fn id_setter_strips_lf_test() {
  let event = ssevents.new("payload") |> ssevents.id("a\nb")
  ssevents.id_of(event) |> should.equal(Some("ab"))
}

pub fn id_setter_strips_nul_test() {
  let event = ssevents.new("payload") |> ssevents.id("with\u{0000}nul")
  ssevents.id_of(event) |> should.equal(Some("withnul"))
}

pub fn new_strips_lone_cr_from_data_test() {
  // #67: a literal CR in `data` cannot survive `decode(encode(x))`
  // verbatim — the wire would coerce it. Strip at construction so
  // `data_of(new(x))` already reflects what the wire would carry.
  let event = ssevents.new("a\rb")
  ssevents.data_of(event) |> should.equal("ab")
}

pub fn new_strips_cr_from_crlf_pair_in_data_test() {
  // The CR half of a CRLF pair is removed; the LF survives as a
  // logical newline (the encoder will emit it as a separate
  // `data:` line).
  let event = ssevents.new("a\r\nb")
  ssevents.data_of(event) |> should.equal("a\nb")
}

pub fn new_strips_nul_from_data_test() {
  // NUL is dropped silently by the decoder per §9.2.6.
  let event = ssevents.new("hello\u{0000}world")
  ssevents.data_of(event) |> should.equal("helloworld")
}

pub fn new_preserves_lf_in_data_test() {
  // LF inside `data` is a *logical* line separator — the encoder
  // splits on it to emit a multi-line `data:` block. Stripping it
  // would lose information that round-trips correctly.
  let event = ssevents.new("first\nsecond")
  ssevents.data_of(event) |> should.equal("first\nsecond")
}

pub fn data_setter_strips_cr_test() {
  // Same rule via the builder helper.
  let event = ssevents.new("ignored") |> ssevents.data("a\rb")
  ssevents.data_of(event) |> should.equal("ab")
}

pub fn from_parts_strips_cr_in_data_test() {
  let event =
    ssevents.from_parts(event_name: None, data: "x\ry", id: None, retry: None)
  ssevents.data_of(event) |> should.equal("xy")
}

pub fn data_round_trips_after_cr_sanitisation_test() {
  // The reproducer from #67: build with CRLF, encode, decode, and
  // confirm the in-memory data after construction equals the
  // post-decode data.
  let event = ssevents.new("a\r\nb")
  let wire = ssevents.encode(event)
  let assert Ok([decoded]) = ssevents.decode(wire)
  ssevents.encode_item(decoded) |> should.equal(wire)
  // And the in-memory value already matches the wire round-trip
  // (CR removed, LF preserved as a logical newline).
  ssevents.data_of(event) |> should.equal("a\nb")
}

pub fn from_parts_strips_lf_in_event_name_test() {
  let event =
    ssevents.from_parts(
      event_name: Some("x\ny"),
      data: "payload",
      id: None,
      retry: None,
    )
  ssevents.name_of(event) |> should.equal(Some("xy"))
}

pub fn from_parts_strips_lf_in_id_test() {
  let event =
    ssevents.from_parts(
      event_name: None,
      data: "payload",
      id: Some("a\nb"),
      retry: None,
    )
  ssevents.id_of(event) |> should.equal(Some("ab"))
}

pub fn from_parts_strips_crlf_pair_in_id_test() {
  // Sanitise CRLF as a unit (not as separate CR + LF) so the inputs
  // CR-only, LF-only, and CRLF all give the same result.
  let event =
    ssevents.from_parts(
      event_name: None,
      data: "payload",
      id: Some("a\r\nb"),
      retry: None,
    )
  ssevents.id_of(event) |> should.equal(Some("ab"))
}

pub fn encode_then_decode_round_trips_after_sanitisation_test() {
  // The whole point of #39: the encoder used to produce
  // non-roundtrippable wire when the caller passed CR/LF/NUL in
  // `event`/`id`. After sanitisation, encode → decode round-trips
  // cleanly (the sanitised value is what comes back).
  let original =
    ssevents.from_parts(
      event_name: Some("noti\nce"),
      data: "payload",
      id: Some("evt\u{0000}1"),
      retry: None,
    )
  let wire = ssevents.encode(original)
  let assert Ok([decoded]) = ssevents.decode(wire)
  let rewire = ssevents.encode_item(decoded)
  rewire |> should.equal(wire)
}

// Construction-time sanitisation for `retry` (#73, #60):
// - `retry/2` (builder) panics on `< 0` because emitting a negative
//   reconnection time violates WHATWG SSE §9.2.6.
// - `retry_clamp/2` is the lenient sibling that clamps `< 0` to `0`.
// - `from_parts/4` (decode-shaped entry point) still silently coerces
//   `< 0` and `> default_max_retry_value` to `None` so
//   `decode(encode(_))` round-trips for any caller-built `Event`.

pub fn retry_setter_drops_value_above_default_max_test() {
  // limit.default_max_retry_value == 86_400_000 (24h in ms).
  let event = ssevents.new("payload") |> ssevents.retry(1_000_000_000)
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn retry_setter_keeps_zero_test() {
  // Zero is a legal retry value (immediate reconnect).
  let event = ssevents.new("payload") |> ssevents.retry(0)
  ssevents.retry_of(event) |> should.equal(Some(0))
}

pub fn retry_setter_keeps_default_max_boundary_test() {
  let event = ssevents.new("payload") |> ssevents.retry(86_400_000)
  ssevents.retry_of(event) |> should.equal(Some(86_400_000))
}

pub fn retry_setter_keeps_one_million_test() {
  // Per the issue: 1_000_000 ms is well below the default 24h cap and
  // must round-trip without coercion.
  let event = ssevents.new("payload") |> ssevents.retry(1_000_000)
  ssevents.retry_of(event) |> should.equal(Some(1_000_000))
}

// --- retry_clamp lenient sibling ---

pub fn retry_clamp_clamps_negative_to_zero_test() {
  let event = ssevents.new("payload") |> ssevents.retry_clamp(-100)
  ssevents.retry_of(event) |> should.equal(Some(0))
}

pub fn retry_clamp_clamps_minus_one_to_zero_test() {
  // Boundary: -1 is the smallest negative; canonical reproducer from #73.
  let event = ssevents.new("payload") |> ssevents.retry_clamp(-1)
  ssevents.retry_of(event) |> should.equal(Some(0))
}

pub fn retry_clamp_keeps_zero_test() {
  let event = ssevents.new("payload") |> ssevents.retry_clamp(0)
  ssevents.retry_of(event) |> should.equal(Some(0))
}

pub fn retry_clamp_passes_through_positive_values_test() {
  let event = ssevents.new("payload") |> ssevents.retry_clamp(2500)
  ssevents.retry_of(event) |> should.equal(Some(2500))
}

pub fn retry_clamp_drops_above_default_max_test() {
  // The clamp lower-bound only floors negatives; values above the
  // default decoder cap still get the silent drop for round-trip with
  // `decode`.
  let event = ssevents.new("payload") |> ssevents.retry_clamp(1_000_000_000)
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn from_parts_drops_negative_retry_test() {
  let event =
    ssevents.from_parts(
      event_name: None,
      data: "payload",
      id: None,
      retry: Some(-100),
    )
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn from_parts_drops_out_of_range_retry_test() {
  let event =
    ssevents.from_parts(
      event_name: None,
      data: "payload",
      id: None,
      retry: Some(1_000_000_000),
    )
  ssevents.retry_of(event) |> should.equal(None)
}

pub fn encode_decode_round_trips_after_retry_sanitisation_test() {
  // Regression for #60: prior versions emitted `retry: -100` /
  // `retry: 1000000000` and the decoder either silently dropped or
  // hard-failed.
  let neg =
    ssevents.from_parts(
      event_name: None,
      data: "x",
      id: None,
      retry: Some(-100),
    )
  let assert Ok([decoded_neg]) = ssevents.decode(ssevents.encode(neg))
  ssevents.encode_item(decoded_neg)
  |> should.equal(ssevents.encode(neg))

  let huge =
    ssevents.from_parts(
      event_name: None,
      data: "x",
      id: None,
      retry: Some(1_000_000_000),
    )
  let assert Ok([decoded_huge]) = ssevents.decode(ssevents.encode(huge))
  ssevents.encode_item(decoded_huge)
  |> should.equal(ssevents.encode(huge))
}

// Issue #77: facade-level Item accessors so callers can pattern-match
// (or filter) on decoded items without reaching into `ssevents/event`.

pub fn is_event_distinguishes_event_and_comment_test() {
  let ev = ssevents.event_item(ssevents.new("hello"))
  let cm = ssevents.comment("ping")
  ssevents.is_event(ev) |> should.equal(True)
  ssevents.is_event(cm) |> should.equal(False)
  ssevents.is_comment(ev) |> should.equal(False)
  ssevents.is_comment(cm) |> should.equal(True)
}

pub fn event_of_item_returns_event_for_event_item_test() {
  let underlying = ssevents.new("payload") |> ssevents.event("job.update")
  let item = ssevents.event_item(underlying)
  case ssevents.event_of_item(item) {
    Some(ev) -> ssevents.name_of(ev) |> should.equal(Some("job.update"))
    None -> should.fail()
  }
}

pub fn event_of_item_returns_none_for_comment_test() {
  ssevents.event_of_item(ssevents.comment("ping"))
  |> should.equal(None)
}

pub fn comment_text_of_item_returns_text_for_comment_test() {
  ssevents.comment_text_of_item(ssevents.comment("ping"))
  |> should.equal(Some("ping"))
}

pub fn comment_text_of_item_returns_none_for_event_test() {
  let item = ssevents.event_item(ssevents.new("payload"))
  ssevents.comment_text_of_item(item) |> should.equal(None)
}

pub fn events_of_filters_to_event_payloads_test() {
  let items = [
    ssevents.event_item(ssevents.named("a", "data-a")),
    ssevents.comment("ignore"),
    ssevents.event_item(ssevents.named("b", "data-b")),
    ssevents.heartbeat(),
  ]
  let events = ssevents.events_of(items)
  case events {
    [first, second] -> {
      ssevents.name_of(first) |> should.equal(Some("a"))
      ssevents.name_of(second) |> should.equal(Some("b"))
    }
    _ -> should.fail()
  }
}

pub fn comment_texts_of_filters_to_comment_text_test() {
  let items = [
    ssevents.event_item(ssevents.new("payload")),
    ssevents.comment("hello"),
    ssevents.comment("world"),
  ]
  ssevents.comment_texts_of(items)
  |> should.equal(["hello", "world"])
}

// The README example from Issue #77 — pin down that pattern-matching
// on a decoded item now works through `ssevents.event_of_item` rather
// than reaching into ssevents/event for the EventItem variant.
pub fn issue_77_decode_and_inspect_first_event_test() {
  let wire = "event: job.update\ndata: hello\n\n"
  let assert Ok(items) = ssevents.decode(wire)
  case ssevents.events_of(items) {
    [first, ..] -> ssevents.name_of(first) |> should.equal(Some("job.update"))
    [] -> should.fail()
  }
}

// ---------- _checked variants (#81) ----------

pub fn event_checked_accepts_safe_name_test() {
  let assert Ok(evt) =
    ssevents.new("data") |> ssevents.event_checked("job.update")
  ssevents.name_of(evt) |> should.equal(Some("job.update"))
}

pub fn event_checked_rejects_lf_in_name_test() {
  ssevents.new("data")
  |> ssevents.event_checked("bad\nname")
  |> should.equal(Error(event.NameContainsControlBytes(value: "bad\nname")))
}

pub fn event_checked_rejects_cr_in_name_test() {
  ssevents.new("data")
  |> ssevents.event_checked("bad\rname")
  |> should.equal(Error(event.NameContainsControlBytes(value: "bad\rname")))
}

pub fn event_checked_rejects_nul_in_name_test() {
  ssevents.new("data")
  |> ssevents.event_checked("bad\u{0000}name")
  |> should.equal(
    Error(event.NameContainsControlBytes(value: "bad\u{0000}name")),
  )
}

pub fn id_checked_accepts_safe_id_test() {
  let assert Ok(evt) = ssevents.new("data") |> ssevents.id_checked("job-1")
  ssevents.id_of(evt) |> should.equal(Some("job-1"))
}

pub fn id_checked_rejects_nul_in_id_test() {
  // The repro from #81 — `id(_, "ab\u{0000}cd")` would silently
  // produce an event with `id = "abcd"`, mutating the
  // authorization-relevant identifier. The strict variant must
  // refuse the input outright.
  ssevents.new("data")
  |> ssevents.id_checked("ab\u{0000}cd")
  |> should.equal(Error(event.IdContainsControlBytes(value: "ab\u{0000}cd")))
}

pub fn named_checked_accepts_safe_inputs_test() {
  let assert Ok(evt) = ssevents.named_checked("topic", "payload")
  ssevents.name_of(evt) |> should.equal(Some("topic"))
  ssevents.data_of(evt) |> should.equal("payload")
}

pub fn named_checked_rejects_lf_in_name_test() {
  ssevents.named_checked("\n", "x")
  |> should.equal(Error(event.NameContainsControlBytes(value: "\n")))
}

pub fn comment_checked_accepts_safe_text_test() {
  let assert Ok(item) = ssevents.comment_checked("ping")
  ssevents.is_comment(item) |> should.equal(True)
}

pub fn comment_checked_rejects_lf_in_text_test() {
  ssevents.comment_checked("multi\nline")
  |> should.equal(
    Error(event.CommentContainsControlBytes(value: "multi\nline")),
  )
}
