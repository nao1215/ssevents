//// Determinism of `ssevents.encode` (#72): the encoded text depends only
//// on the value of the `Event`, not on the order of the builder calls
//// that made it.

import gleam/list
import gleeunit/should
import ssevents

pub fn encode_invariant_under_builder_call_order_test() {
  let canonical =
    ssevents.named("custom", "payload")
    |> ssevents.id("evt-1")
    |> ssevents.retry(2500)
  let reordered =
    ssevents.named("custom", "payload")
    |> ssevents.retry(2500)
    |> ssevents.id("evt-1")

  canonical |> should.equal(reordered)
  ssevents.encode(reordered) |> should.equal(ssevents.encode(canonical))
}

pub fn encode_invariant_under_idempotent_setter_test() {
  let once = ssevents.new("payload") |> ssevents.id("evt-1")
  let twice =
    ssevents.new("payload") |> ssevents.id("evt-1") |> ssevents.id("evt-1")

  ssevents.encode(twice) |> should.equal(ssevents.encode(once))
}

pub fn encode_invariant_under_last_write_wins_test() {
  let direct = ssevents.new("payload") |> ssevents.id("final")
  let overridden =
    ssevents.new("payload") |> ssevents.id("draft") |> ssevents.id("final")

  ssevents.encode(overridden) |> should.equal(ssevents.encode(direct))
}

pub fn encode_writes_fields_in_a_fixed_order_test() {
  [
    ssevents.named("e", "d") |> ssevents.id("i") |> ssevents.retry(1),
    ssevents.named("e", "d") |> ssevents.retry(1) |> ssevents.id("i"),
  ]
  |> list.each(fn(event) {
    ssevents.encode(event)
    |> should.equal("event: e\nid: i\nretry: 1\ndata: d\n\n")
  })
}
