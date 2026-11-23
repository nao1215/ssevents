//// The rules of "Interpreting an event stream" in the WHATWG HTML
//// standard, one test per rule:
//// https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{EventItem, ReconnectItem, ReconnectState}

fn decode(bytes: BitArray) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(bytes, ssevents.default_limits)
}

pub fn event_without_closing_blank_line_is_dropped_test() {
  // "If the file ends in the middle of an event, before the final empty
  // line, the incomplete event is not dispatched."
  decode(<<"data: tail":utf8>>) |> should.equal(Ok([]))
  decode(<<"data: tail\n":utf8>>) |> should.equal(Ok([]))
  decode(<<"data: tail\r":utf8>>) |> should.equal(Ok([]))
  decode(<<"data: a\n\ndata: tail\r\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("a"))]))
}

pub fn invalid_utf8_becomes_replacement_character_test() {
  // The stream is read with the UTF-8 decode algorithm, which replaces
  // each maximal invalid sequence with one U+FFFD instead of failing.
  decode(<<"data: a":utf8, 0xFF, "b\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("a\u{FFFD}b"))]))
  // A truncated sequence is one replacement, and the byte that cut it
  // short is read again.
  decode(<<"data: ":utf8, 0xE2, 0x82, "x\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("\u{FFFD}x"))]))
  // An overlong form and a surrogate are one replacement per byte.
  decode(<<"data: ":utf8, 0xC0, 0xAF, 0xED, 0xA0, 0x80, "\n\n":utf8>>)
  |> should.equal(
    Ok([EventItem(ssevents.new("\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"))]),
  )
  // F0 needs 90..BF next, so F0 80 is two replacements.
  decode(<<"data: ":utf8, 0xF0, 0x80, 0xF0, 0x9F, 0x98, "\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("\u{FFFD}\u{FFFD}\u{FFFD}"))]))
  // A field name with an invalid byte is an unknown field.
  decode(<<0xFF, ": x\ndata: y\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("y"))]))
}

pub fn nul_in_data_and_event_name_is_kept_test() {
  // Only the `id` field has a NUL rule. `data` and `event` keep it.
  let assert Ok([EventItem(event)]) =
    decode(<<"event: a\u{0000}b\ndata: c\u{0000}d\n\n":utf8>>)
  ssevents.data_of(event) |> should.equal("c\u{0000}d")
  ssevents.name_of(event) |> should.be_some |> should.equal("a\u{0000}b")
  ssevents.data_of(ssevents.new("c\u{0000}d")) |> should.equal("c\u{0000}d")
}

pub fn byte_order_mark_split_across_chunks_does_not_count_as_a_line_test() {
  // A chunk that ends inside the byte order mark leaves up to two bytes
  // waiting. They are not part of a line, so a small `max_line_bytes`
  // must not reject them while `decode` on the whole input accepts it.
  let limits = ssevents.Limits(..ssevents.default_limits, max_line_bytes: 0)
  let decoder = ssevents.new_decoder(limits)
  let assert Ok(#(decoder, [])) = ssevents.push(decoder, <<0xEF>>)
  let assert Ok(#(decoder, [])) = ssevents.push(decoder, <<0xBB>>)
  let assert Ok(#(_, [])) = ssevents.push(decoder, <<0xBF, "\n":utf8>>)
  ssevents.decode(<<0xEF, 0xBB, 0xBF, "\n":utf8>>, limits)
  |> should.equal(Ok([]))
}

pub fn block_without_data_reports_id_and_retry_test() {
  // A blank line after a block with no `data` dispatches nothing, but the
  // browser still takes the last event id from the block and has already
  // set the reconnection time from its `retry`.
  decode(<<"retry: 1500\n\n":utf8>>)
  |> should.equal(Ok([ReconnectItem(id: None, retry: Some(1500))]))
  decode(<<"id: 7\nevent: x\n\n":utf8>>)
  |> should.equal(Ok([ReconnectItem(id: Some("7"), retry: None)]))
  // `id` without a value clears the last event id.
  decode(<<"id\n\n":utf8>>)
  |> should.equal(Ok([ReconnectItem(id: Some(""), retry: None)]))
  // Nothing to report: no item.
  decode(<<"event: x\nretry: nope\nid: a\u{0000}b\n\n":utf8>>)
  |> should.equal(Ok([]))
}

pub fn retry_of_an_unfinished_block_is_reported_test() {
  // The reconnection time is set when the `retry` line is read, so it
  // counts even when the stream ends before the blank line. The id and
  // the event of that block are dropped.
  decode(<<"id: 3\nretry: 10\ndata: x\n":utf8>>)
  |> should.equal(Ok([ReconnectItem(id: None, retry: Some(10))]))
  // A last line without its line ending is not read at all.
  decode(<<"retry: 10":utf8>>) |> should.equal(Ok([]))
}

pub fn reconnect_item_updates_reconnect_state_test() {
  let assert Ok(items) =
    decode(<<"id: 1\ndata: a\n\nretry: 50\n\nid: 2\n\n":utf8>>)
  list.fold(items, ReconnectState(None, None), ssevents.update_reconnect)
  |> should.equal(ReconnectState(last_event_id: Some("2"), retry: Some(50)))
  ssevents.update_reconnect(
    ReconnectState(Some("2"), Some(50)),
    ReconnectItem(id: Some(""), retry: None),
  )
  |> should.equal(ReconnectState(last_event_id: None, retry: Some(50)))
}

pub fn reconnect_item_encodes_as_a_block_without_data_test() {
  ssevents.encode_items([ReconnectItem(id: None, retry: Some(5000))])
  |> should.equal("retry: 5000\n\n")
  ssevents.encode_items([ReconnectItem(id: Some("7"), retry: Some(1))])
  |> should.equal("id: 7\nretry: 1\n\n")
  ssevents.encode_items([ReconnectItem(id: Some(""), retry: None)])
  |> should.equal("id:\n\n")
  // A field that `id` or `retry` would refuse is left out, so the value
  // cannot add lines to the stream.
  ssevents.encode_items([
    ReconnectItem(id: Some("a\nretry: 1"), retry: Some(-1)),
  ])
  |> should.equal("")
  ssevents.encode_items([ReconnectItem(id: None, retry: None)])
  |> should.equal("")
}

pub fn finish_never_fails_test() {
  let decoder = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(decoder, [])) =
    ssevents.push(decoder, <<"retry: 9\ndata: ":utf8, 0xFF>>)
  ssevents.finish(decoder)
  |> should.equal([ReconnectItem(id: None, retry: Some(9))])
}

pub fn builders_reject_line_breaks_test() {
  ["a\nb", "a\rb", "a\r\nb", "\n"]
  |> list.each(fn(bad) {
    ssevents.named(bad, "x") |> should.equal(Error(Nil))
    ssevents.new("x") |> ssevents.id(bad) |> should.equal(Error(Nil))
    ssevents.comment(bad) |> should.equal(Error(Nil))
  })
  // A NUL makes a browser ignore the whole `id` field.
  ssevents.new("x") |> ssevents.id("a\u{0000}b") |> should.equal(Error(Nil))
  let assert Ok(event) = ssevents.named("a\u{0000}b", "x")
  ssevents.name_of(event) |> should.equal(Some("a\u{0000}b"))
  let assert Ok(_) = ssevents.comment("a\u{0000}b")
}

pub fn negative_and_zero_limits_fail_closed_test() {
  // Every limit below 1 rejects the input it bounds, the same way for
  // `decode` and for `push`, and never lets anything through.
  let zero =
    ssevents.Limits(
      max_line_bytes: 0,
      max_event_bytes: 0,
      max_data_lines: 0,
      max_retry_value: 0,
    )
  decode_with(<<"\n\n":utf8>>, zero) |> should.equal(Ok([]))
  decode_with(<<"data\n\n":utf8>>, zero)
  |> should.equal(Error(ssevents.LineTooLong(0)))
  let negative =
    ssevents.Limits(
      max_line_bytes: -1,
      max_event_bytes: -1,
      max_data_lines: -1,
      max_retry_value: -1,
    )
  decode_with(<<"\n":utf8>>, negative)
  |> should.equal(Error(ssevents.LineTooLong(-1)))
  decode_with(
    <<"data: x\n\n":utf8>>,
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: -1),
  )
  |> should.equal(Error(ssevents.EventTooLarge(-1)))
  decode_with(
    <<"data: x\n\n":utf8>>,
    ssevents.Limits(..ssevents.default_limits, max_data_lines: 0),
  )
  |> should.equal(Error(ssevents.TooManyDataLines(0)))
  decode_with(
    <<"retry: 0\ndata: x\n\n":utf8>>,
    ssevents.Limits(..ssevents.default_limits, max_retry_value: -1),
  )
  |> should.equal(Ok([EventItem(ssevents.new("x"))]))
}

fn decode_with(
  bytes: BitArray,
  limits: ssevents.Limits,
) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(bytes, limits)
}

pub fn update_reconnect_ignores_refused_fields_of_a_hand_built_item_test() {
  // Found by code review: a hand-built ReconnectItem could put CRLF into
  // the id that a client sends back as a header, or a negative retry.
  ssevents.update_reconnect(
    ReconnectState(Some("1"), Some(50)),
    ReconnectItem(id: Some("a\r\nX-Evil: 1"), retry: Some(-5)),
  )
  |> should.equal(ReconnectState(last_event_id: Some("1"), retry: Some(50)))
  ssevents.update_reconnect(
    ReconnectState(None, None),
    ReconnectItem(id: Some("a\u{0000}"), retry: Some(86_400_001)),
  )
  |> should.equal(ReconnectState(None, None))
}

pub fn utf8_sequences_at_the_edges_of_each_range_test() {
  // The first and last valid lead and continuation bytes of each range
  // are read as text, and the byte just outside is one U+FFFD.
  let valid = <<
    0xC2, 0x80, 0xDF, 0xBF, 0xE0, 0xA0, 0x80, 0xE1, 0x80, 0x80, 0xEC, 0xBF, 0xBF,
    0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80, 0xEF, 0xBF, 0xBF, 0xF0, 0x90, 0x80, 0x80,
    0xF1, 0x80, 0x80, 0x80, 0xF3, 0xBF, 0xBF, 0xBF, 0xF4, 0x8F, 0xBF, 0xBF,
  >>
  let assert Ok(text) = bit_array.to_string(valid)
  decode(<<"data: a":utf8, valid:bits, "b\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("a" <> text <> "b"))]))
  // With an invalid byte on the same line the slow path reads them.
  decode(<<"data: a":utf8, valid:bits, 0xFF, "b\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("a" <> text <> "\u{FFFD}b"))]))
  // A continuation byte after a complete sequence starts a new one.
  decode(<<"data: ":utf8, 0xC2, 0x80, 0x80, "\n\n":utf8>>)
  |> should.equal(Ok([EventItem(ssevents.new("\u{0080}\u{FFFD}"))]))
  let bad = "\u{FFFD}"
  [
    #(<<0x80>>, bad),
    #(<<0xBF>>, bad),
    #(<<0xC1, 0xBF>>, bad <> bad),
    #(<<0xE0, 0x9F, 0xBF>>, bad <> bad <> bad),
    #(<<0xED, 0xA0>>, bad <> bad),
    #(<<0xF0, 0x8F>>, bad <> bad),
    #(<<0xF4, 0x90>>, bad <> bad),
    #(<<0xF5, 0x80>>, bad <> bad),
    #(<<0xC2, 0xC0>>, bad <> bad),
    #(<<0xE1, 0x80, 0xC0>>, bad <> bad),
  ]
  |> list.each(fn(case_) {
    let #(bytes, expected) = case_
    decode(<<"data: a":utf8, bytes:bits, "b\n\n":utf8>>)
    |> should.equal(Ok([EventItem(ssevents.new("a" <> expected <> "b"))]))
  })
}
