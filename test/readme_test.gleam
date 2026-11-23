//// The README examples and the doc comment examples, run on both targets.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import ssevents.{EventItem, EventTooLarge, LineTooLong, ReconnectState}

// The chunked reader from the README.
fn read_body(chunks: List(BitArray)) {
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 16_384)
  let start = #(ssevents.new_decoder(limits), [])
  use #(decoder, items) <- result.try(
    list.try_fold(chunks, start, fn(acc, chunk) {
      let #(decoder, items) = acc
      use #(decoder, new) <- result.map(ssevents.push(decoder, chunk))
      #(decoder, list.append(items, new))
    }),
  )
  use rest <- result.map(ssevents.finish(decoder))
  list.append(items, rest)
}

pub fn readme_read_body_test() {
  read_body([<<"event: a\nda":utf8>>, <<"ta: 1\n\n: hi\ndata: 2":utf8>>])
  |> should.equal(
    Ok([
      EventItem(ssevents.named("a", "1")),
      ssevents.comment("hi"),
      EventItem(ssevents.new("2")),
    ]),
  )
  read_body([<<"data: ":utf8>>, <<0:size(131_072)>>, <<"\n\n":utf8>>])
  |> should.equal(Error(LineTooLong(8192)))
  let line = <<"data: ":utf8, 0:size(48_000), "\n":utf8>>
  read_body([line, line, line])
  |> should.equal(Error(EventTooLarge(16_384)))
}

pub fn readme_reconnect_test() {
  [
    EventItem(ssevents.new("a") |> ssevents.id("1") |> ssevents.retry(500)),
    ssevents.comment("ping"),
    EventItem(ssevents.new("b")),
  ]
  |> list.fold(ReconnectState(None, None), ssevents.update_reconnect)
  |> should.equal(ReconnectState(last_event_id: Some("1"), retry: Some(500)))
}

pub fn new_doc_test() {
  ssevents.new("a\r\nb") |> ssevents.data_of |> should.equal("a\nb")
}

pub fn named_doc_test() {
  ssevents.named("job.done", "42")
  |> ssevents.name_of
  |> should.equal(Some("job.done"))
}

pub fn retry_doc_test() {
  ssevents.new("x")
  |> ssevents.retry(5000)
  |> ssevents.retry_of
  |> should.equal(Some(5000))
  ssevents.new("x")
  |> ssevents.retry(-1)
  |> ssevents.retry_of
  |> should.equal(None)
}

pub fn comment_doc_test() {
  ssevents.encode_items([ssevents.comment("ping")])
  |> should.equal(": ping\n")
}

pub fn encode_doc_test() {
  ssevents.named("update", "a\nb")
  |> ssevents.id("7")
  |> ssevents.encode
  |> should.equal("event: update\nid: 7\ndata: a\ndata: b\n\n")
}

pub fn encode_items_doc_test() {
  ssevents.encode_items([
    ssevents.comment("hello"),
    ssevents.EventItem(ssevents.new("x")),
  ])
  |> should.equal(": hello\ndata: x\n\n")
}

pub fn decode_doc_test() {
  ssevents.decode(<<"event: ping\ndata: 1\n\n":utf8>>, ssevents.default_limits)
  |> should.equal(Ok([ssevents.EventItem(ssevents.named("ping", "1"))]))
  ssevents.decode(
    <<"data: hello\n\n":utf8>>,
    ssevents.Limits(..ssevents.default_limits, max_line_bytes: 4),
  )
  |> should.equal(Error(ssevents.LineTooLong(limit: 4)))
}

pub fn push_doc_test() {
  let decoder = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(decoder, [])) = ssevents.push(decoder, <<"data: he":utf8>>)
  let assert Ok(#(_, items)) = ssevents.push(decoder, <<"llo\n\n":utf8>>)
  items |> should.equal([ssevents.EventItem(ssevents.new("hello"))])
}

pub fn limits_doc_test() {
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 200_000)
  limits.max_event_bytes |> should.equal(200_000)
  limits.max_line_bytes |> should.equal(8192)
}
