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
