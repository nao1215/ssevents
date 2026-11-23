//// The README examples and the doc comment examples, run on both targets.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import ssevents.{
  EventItem, EventTooLarge, LineTooLong, ReconnectItem, ReconnectState,
}
import support

// The chunked reader from the README.
fn read_body(chunks: List(BitArray)) {
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 16_384)
  let start = #(ssevents.new_decoder(limits), [])
  use #(decoder, items) <- result.map(
    list.try_fold(chunks, start, fn(acc, chunk) {
      let #(decoder, items) = acc
      use #(decoder, new) <- result.map(ssevents.push(decoder, chunk))
      #(decoder, list.append(items, new))
    }),
  )
  list.append(items, ssevents.finish(decoder))
}

pub fn readme_read_body_test() {
  read_body([<<"event: a\nda":utf8>>, <<"ta: 1\n\n: hi\ndata: 2":utf8>>])
  |> should.equal(
    Ok([EventItem(support.named("a", "1")), support.comment("hi")]),
  )
  read_body([<<"data: ":utf8>>, <<0:size(131_072)>>, <<"\n\n":utf8>>])
  |> should.equal(Error(LineTooLong(8192)))
  let line = <<"data: ":utf8, 0:size(48_000), "\n":utf8>>
  read_body([line, line, line])
  |> should.equal(Error(EventTooLarge(16_384)))
}

pub fn readme_quick_start_test() {
  let assert Ok(opened) = ssevents.comment("stream opened")
  let assert Ok(started) =
    ssevents.named("job.started", "build #42")
    |> result.try(ssevents.id(_, "cursor-1"))
  let items = [
    opened,
    ReconnectItem(id: None, retry: Some(5000)),
    EventItem(started),
    EventItem(ssevents.new("step 1/3\nrunning lints")),
  ]
  let body = ssevents.encode_items(items)
  body
  |> should.equal(
    ": stream opened\nretry: 5000\n\nevent: job.started\nid: cursor-1\ndata: build #42\n\ndata: step 1/3\ndata: running lints\n\n",
  )
  ssevents.decode(<<body:utf8>>, ssevents.default_limits)
  |> should.equal(Ok(items))
}

pub fn readme_reconnect_test() {
  [
    EventItem(support.id(ssevents.new("a"), "1") |> ssevents.retry(500)),
    support.comment("ping"),
    EventItem(ssevents.new("b")),
    ReconnectItem(id: Some("2"), retry: None),
  ]
  |> list.fold(ReconnectState(None, None), ssevents.update_reconnect)
  |> should.equal(ReconnectState(last_event_id: Some("2"), retry: Some(500)))
}

pub fn new_doc_test() {
  ssevents.new("a\r\nb") |> ssevents.data_of |> should.equal("a\nb")
}

pub fn named_doc_test() {
  ssevents.named("job.done", "42")
  |> result.map(ssevents.name_of)
  |> should.equal(Ok(Some("job.done")))
  ssevents.named("job\ndata: forged", "42") |> should.equal(Error(Nil))
}

pub fn id_doc_test() {
  ssevents.new("x")
  |> ssevents.id("7")
  |> result.map(ssevents.id_of)
  |> should.equal(Ok(Some("7")))
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
  let assert Ok(ping) = ssevents.comment("ping")
  ssevents.encode_items([ping])
  |> should.equal(": ping\n")
}

pub fn encode_doc_test() {
  ssevents.new("a\nb")
  |> ssevents.retry(500)
  |> ssevents.encode
  |> should.equal("retry: 500\ndata: a\ndata: b\n\n")
}

pub fn encode_items_doc_test() {
  ssevents.encode_items([
    ssevents.EventItem(ssevents.new("x")),
    ssevents.ReconnectItem(id: None, retry: Some(5000)),
  ])
  |> should.equal("data: x\n\nretry: 5000\n\n")
}

pub fn decode_doc_test() {
  ssevents.decode(<<"data: 1\n\nretry: 50\n\n":utf8>>, ssevents.default_limits)
  |> should.equal(
    Ok([
      ssevents.EventItem(ssevents.new("1")),
      ssevents.ReconnectItem(id: None, retry: Some(50)),
    ]),
  )
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
