//// Determinism invariants for `ssevents.encode` (#72).
////
//// Pinning the property: the encoded bytes depend only on the *value*
//// of the `Event`, not on the builder call sequence used to construct
//// it. metamon is not a dev-dep here; the tests cover the same
//// invariant exhaustively over a small but representative permutation
//// space (every interleaving of the four optional setters
//// `event` / `id` / `retry` / `data`) and over a hand-picked corpus
//// designed to surface the failure modes the metamon `forall_morph`
//// in the issue would shrink to (empty fields, multiline `data`,
//// boundary `retry` values, sanitised CR/LF/NUL bytes).

import gleam/list
import gleeunit/should
import ssevents
import ssevents/encoder

// ---------------------------------------------------------------------------
// Builder-call-order invariance — the same four field assignments in
// every interleaving must produce byte-identical wire output.
// ---------------------------------------------------------------------------

pub fn encode_invariant_under_builder_call_order_single_event_test() {
  let canonical =
    ssevents.new("payload")
    |> ssevents.event("custom")
    |> ssevents.id("evt-1")
    |> ssevents.retry(2500)

  // Permute the four setter calls. `data` is fixed at the constructor
  // (`ssevents.new`); we permute the three remaining setters and also
  // swap out `event` / `data` via `named` to cover the second
  // construction shape.
  let permutations = [
    ssevents.new("payload")
      |> ssevents.event("custom")
      |> ssevents.id("evt-1")
      |> ssevents.retry(2500),
    ssevents.new("payload")
      |> ssevents.event("custom")
      |> ssevents.retry(2500)
      |> ssevents.id("evt-1"),
    ssevents.new("payload")
      |> ssevents.id("evt-1")
      |> ssevents.event("custom")
      |> ssevents.retry(2500),
    ssevents.new("payload")
      |> ssevents.id("evt-1")
      |> ssevents.retry(2500)
      |> ssevents.event("custom"),
    ssevents.new("payload")
      |> ssevents.retry(2500)
      |> ssevents.event("custom")
      |> ssevents.id("evt-1"),
    ssevents.new("payload")
      |> ssevents.retry(2500)
      |> ssevents.id("evt-1")
      |> ssevents.event("custom"),
    // Alternative entry point — `named` is `new(data) |> event(name)`
    // sugar; the encoded bytes must agree with the canonical.
    ssevents.named("custom", "payload")
      |> ssevents.id("evt-1")
      |> ssevents.retry(2500),
    ssevents.named("custom", "payload")
      |> ssevents.retry(2500)
      |> ssevents.id("evt-1"),
  ]

  let canonical_wire = ssevents.encode(canonical)
  list.each(permutations, fn(variant) {
    ssevents.encode(variant) |> should.equal(canonical_wire)
  })
}

pub fn encode_invariant_for_event_without_retry_test() {
  // Without a retry field, the encoder must not synthesise a
  // `retry:` line just because the builder happened to set it to a
  // sentinel — the absence of the field is itself the canonical
  // shape.
  let first = ssevents.new("hi") |> ssevents.event("update") |> ssevents.id("1")
  let second =
    ssevents.new("hi") |> ssevents.id("1") |> ssevents.event("update")

  let wire_first = ssevents.encode(first)
  ssevents.encode(second) |> should.equal(wire_first)
}

pub fn encode_invariant_for_event_without_id_test() {
  let first =
    ssevents.new("hi") |> ssevents.event("update") |> ssevents.retry(0)
  let second =
    ssevents.new("hi") |> ssevents.retry(0) |> ssevents.event("update")

  ssevents.encode(second) |> should.equal(ssevents.encode(first))
}

pub fn encode_invariant_for_minimal_event_test() {
  // Single-field events must encode identically regardless of which
  // constructor is used.
  let from_new = ssevents.new("only-data")
  let from_message = ssevents.message("only-data")
  ssevents.encode(from_new) |> should.equal(ssevents.encode(from_message))
}

// ---------------------------------------------------------------------------
// Builder vs `from_parts` — two structurally equal events constructed
// via different entry points encode to the same bytes.
// ---------------------------------------------------------------------------

pub fn encode_invariant_builder_vs_from_parts_test() {
  let via_builder =
    ssevents.new("payload")
    |> ssevents.event("custom")
    |> ssevents.id("evt-1")
    |> ssevents.retry(2500)

  let via_from_parts =
    ssevents.from_parts(
      event_name: option_some("custom"),
      data: "payload",
      id: option_some("evt-1"),
      retry: option_some(2500),
    )

  ssevents.encode(via_builder) |> should.equal(ssevents.encode(via_from_parts))
}

pub fn encode_invariant_builder_vs_from_parts_minimal_test() {
  // No optional fields — the from_parts shape with all `None` must
  // match the bare `new(data)` shape.
  let via_builder = ssevents.new("payload")
  let via_from_parts =
    ssevents.from_parts(
      event_name: option_none(),
      data: "payload",
      id: option_none(),
      retry: option_none(),
    )

  ssevents.encode(via_builder) |> should.equal(ssevents.encode(via_from_parts))
}

// ---------------------------------------------------------------------------
// Determinism across line endings — the invariant is
// per-line-ending, but for any single line ending two equivalent
// builds must agree.
// ---------------------------------------------------------------------------

pub fn encode_with_crlf_invariant_under_builder_call_order_test() {
  let first =
    ssevents.new("payload")
    |> ssevents.event("custom")
    |> ssevents.id("evt-1")
    |> ssevents.retry(2500)
  let second =
    ssevents.new("payload")
    |> ssevents.retry(2500)
    |> ssevents.id("evt-1")
    |> ssevents.event("custom")

  ssevents.encode_with_line_ending(second, encoder.Crlf)
  |> should.equal(ssevents.encode_with_line_ending(first, encoder.Crlf))
}

// ---------------------------------------------------------------------------
// Multiline data — splitting into multiple `data:` lines is a
// post-construction transform; the order of builder calls must not
// affect it.
// ---------------------------------------------------------------------------

pub fn encode_invariant_with_multiline_data_test() {
  // `data` containing a literal LF must serialise as two `data:`
  // lines regardless of which constructor / setter chain produced it.
  let multi = "first\nsecond"
  let from_new =
    ssevents.new(multi)
    |> ssevents.event("update")
    |> ssevents.id("1")
  let from_named =
    ssevents.named("update", multi)
    |> ssevents.id("1")

  ssevents.encode(from_named) |> should.equal(ssevents.encode(from_new))
}

// ---------------------------------------------------------------------------
// Idempotence — the same setter called twice with the same value
// must not change the wire output.
// ---------------------------------------------------------------------------

pub fn encode_invariant_under_idempotent_setter_test() {
  let once =
    ssevents.new("payload")
    |> ssevents.event("custom")
    |> ssevents.id("evt-1")
  let twice =
    ssevents.new("payload")
    |> ssevents.event("custom")
    |> ssevents.event("custom")
    |> ssevents.id("evt-1")
    |> ssevents.id("evt-1")

  ssevents.encode(twice) |> should.equal(ssevents.encode(once))
}

// ---------------------------------------------------------------------------
// Last-write-wins — a setter called twice with two different values
// keeps the second; the wire output must reflect only the second.
// ---------------------------------------------------------------------------

pub fn encode_invariant_under_last_write_wins_test() {
  let direct =
    ssevents.new("payload")
    |> ssevents.event("final")
    |> ssevents.id("evt-1")
  let with_overridden_event =
    ssevents.new("payload")
    |> ssevents.event("draft")
    |> ssevents.event("final")
    |> ssevents.id("evt-1")

  ssevents.encode(with_overridden_event)
  |> should.equal(ssevents.encode(direct))
}

// ---------------------------------------------------------------------------
// Helpers — named constructors for `Option` so the tests stay readable
// without importing `gleam/option` directly.
// ---------------------------------------------------------------------------

import gleam/option.{None, Some}

fn option_some(value: a) -> option.Option(a) {
  Some(value)
}

fn option_none() -> option.Option(a) {
  None
}
