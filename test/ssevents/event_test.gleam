import gleam/option.{None, Some}
import gleeunit/should
import ssevents

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

// Construction-time sanitisation for `retry`: a negative value is
// silently dropped on decode by §9.2.6 ASCII-digits rule, and any
// value above the default 24-hour cap hard-fails the decoder. Both
// shapes are coerced to `None` at construction so encode → decode
// is a no-op.

pub fn retry_setter_drops_negative_test() {
  let event = ssevents.new("payload") |> ssevents.retry(-100)
  ssevents.retry_of(event) |> should.equal(None)
}

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
