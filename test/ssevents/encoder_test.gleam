import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import ssevents
import ssevents/encoder
import ssevents/event

pub fn encode_multiline_event_with_lf_test() {
  let event =
    ssevents.from_parts(
      event_name: Some("update"),
      data: "line1\nline2",
      id: Some("abc"),
      retry: Some(2500),
    )

  ssevents.encode(event)
  |> should.equal(
    "event: update\nid: abc\nretry: 2500\ndata: line1\ndata: line2\n\n",
  )
}

pub fn encode_comment_and_heartbeat_test() {
  ssevents.comment("keepalive")
  |> ssevents.encode_item
  |> should.equal(": keepalive\n")

  ssevents.heartbeat()
  |> ssevents.encode_item
  |> should.equal(": heartbeat\n")
}

pub fn encode_empty_data_event_emits_explicit_data_line_test() {
  ssevents.new("")
  |> ssevents.encode
  |> should.equal("data:\n\n")
}

pub fn encode_event_with_crlf_test() {
  ssevents.new("test")
  |> ssevents.encode_with_line_ending(encoder.Crlf)
  |> should.equal("data: test\r\n\r\n")
}

pub fn encode_multiline_event_with_crlf_test() {
  let event =
    ssevents.named("job.update", "line1\nline2")
    |> ssevents.id("cursor-1")

  ssevents.encode_with_line_ending(event, encoder.Crlf)
  |> should.equal(
    "event: job.update\r\nid: cursor-1\r\ndata: line1\r\ndata: line2\r\n\r\n",
  )
}

pub fn encode_comment_with_crlf_test() {
  ssevents.comment("hello")
  |> ssevents.encode_item_with_line_ending(encoder.Crlf)
  |> should.equal(": hello\r\n")
}

pub fn encode_items_with_crlf_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.new("payload") |> ssevents.event_item,
  ]

  let encoded = ssevents.encode_items_with_line_ending(items, encoder.Crlf)
  encoded |> should.equal(": meta\r\ndata: payload\r\n\r\n")

  let assert Ok(decoded) = ssevents.decode(encoded)
  decoded |> should.equal(items)
}

pub fn encode_bytes_matches_string_encoding_test() {
  let event =
    ssevents.named("job.update", "payload")
    |> ssevents.id("cursor-1")

  ssevents.encode_bytes(event)
  |> should.equal(bit_array.from_string(ssevents.encode(event)))
}

pub fn encode_item_bytes_matches_string_encoding_test() {
  let item = ssevents.comment("meta")

  ssevents.encode_item_bytes(item)
  |> should.equal(bit_array.from_string(ssevents.encode_item(item)))
}

pub fn encode_items_bytes_matches_item_concatenation_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.new("payload") |> ssevents.event_item,
  ]

  ssevents.encode_items_bytes(items)
  |> should.equal(
    items
    |> list.map(ssevents.encode_item_bytes)
    |> bit_array.concat,
  )
}

pub fn encode_normalises_lone_cr_between_lf_pair_test() {
  // Input " 0Az~\n\r\r\n" used to leak a lone CR into the wire.
  // `event.new` now rewrites every CR to LF at construction, so the
  // encoder never sees a CR byte and the round trip is closed at
  // construction rather than at encode.
  let event = ssevents.new(" 0Az~\n\r\r\n")
  let wire = ssevents.encode(event)

  // No CR byte must appear anywhere in the encoded output.
  bit_array.from_string(wire)
  |> contains_byte(13)
  |> should.equal(False)

  // The data field must round-trip through encode/decode losslessly.
  // Each CR became LF at construction, so every line break of the
  // original input survives.
  let assert Ok([decoded_item]) = ssevents.decode(wire)
  let assert event.EventItem(decoded_event) = decoded_item
  ssevents.data_of(decoded_event)
  |> should.equal(ssevents.data_of(event))
}

pub fn encode_decode_round_trips_data_to_its_lf_form_test() {
  // WHATWG SSE treats CR, LF and CRLF alike as line terminators, so the
  // only change a round trip may make to `data` is rewriting each of
  // them to LF. Lone CRs used to be dropped and a trailing CR lost its
  // line, so the decoded data came back shorter than the input.
  [
    " 0Az~\n\r\r\n", "\n", "\n\n", "\n\n\n", "abc", "abc\n", "abc\n\n",
    "a\nb\nc", "a\r\nb\r\nc", "a\rb\rc", "with\rcr",
    "all\nmixed\r\nthings\rhere", "abc\r", "\r", "\r\r\r", "\r\n", "\r\r\n",
    "\n\r", "leading\rstart", "",
  ]
  |> list.each(fn(input) {
    let wire = ssevents.encode(ssevents.new(input))
    let assert Ok([event.EventItem(decoded)]) = ssevents.decode(wire)
    ssevents.data_of(decoded) |> should.equal(to_lf(input))
  })
}

/// CRLF and lone CR to LF, by code point. `string.replace` cannot be
/// the oracle here: it works on graphemes on Erlang and on code units on
/// JavaScript, and rewriting `"\r\r\n"` in two passes forms a new CRLF.
fn to_lf(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
  |> lf_codepoints([])
}

fn lf_codepoints(codes: List(Int), acc: List(Int)) -> String {
  case codes {
    [] ->
      acc
      |> list.reverse
      |> list.filter_map(string.utf_codepoint)
      |> string.from_utf_codepoints
    [13, 10, ..rest] | [13, ..rest] -> lf_codepoints(rest, [10, ..acc])
    [code, ..rest] -> lf_codepoints(rest, [code, ..acc])
  }
}

pub fn encode_normalises_isolated_cr_test() {
  // A lone CR with no trailing LF becomes a line break, not nothing.
  ssevents.encode(ssevents.new("a\rb"))
  |> should.equal("data: a\ndata: b\n\n")
}

pub fn encode_keeps_leading_byte_order_mark_in_data_test() {
  // U+FEFF is ordinary text inside a `data` value. Only a BOM at the
  // very start of the stream is special to SSE decoders, and a `data:`
  // line never starts the stream with it. Both targets must emit it.
  ssevents.encode(ssevents.new("\u{FEFF}x"))
  |> should.equal("data: \u{FEFF}x\n\n")
}

pub fn encode_comment_strips_lf_to_keep_round_trip_test() {
  // Regression for #61: previously `Comment("a\nb")` encoded to
  // `: a\n: b\n` and decoded back to two separate `Comment`
  // values. Sanitisation now lives at construction (#68), so the
  // encoder writes a single `:` line and decode returns one
  // `Comment` matching the sanitised text.
  let item = event.CommentItem(event.comment("a\nb"))
  let wire = ssevents.encode_item(item)
  let assert Ok(decoded) = ssevents.decode(wire)
  decoded |> should.equal([event.CommentItem(event.comment("ab"))])
}

pub fn encode_comment_strips_cr_test() {
  let item = event.CommentItem(event.comment("a\rb"))
  let wire = ssevents.encode_item(item)
  let assert Ok(decoded) = ssevents.decode(wire)
  decoded |> should.equal([event.CommentItem(event.comment("ab"))])
}

pub fn encode_comment_strips_crlf_pair_test() {
  let item = event.CommentItem(event.comment("a\r\nb"))
  let wire = ssevents.encode_item(item)
  let assert Ok(decoded) = ssevents.decode(wire)
  decoded |> should.equal([event.CommentItem(event.comment("ab"))])
}

pub fn encode_comment_round_trips_to_single_comment_test() {
  // After sanitisation the encoded wire is exactly one `:` line, so
  // decode returns exactly one `Comment` matching the sanitised
  // input.
  let item = event.CommentItem(event.comment("multi\nline\rdiagnostic"))
  let wire = ssevents.encode_item(item)
  let assert Ok(decoded) = ssevents.decode(wire)
  decoded
  |> should.equal([event.CommentItem(event.comment("multilinediagnostic"))])
}

pub fn encode_splits_oversized_data_line_for_decoder_limit_test() {
  // Regression for #88: prior versions wrote `data:` values verbatim,
  // so a payload longer than ~8184 bytes produced wire bytes the
  // default decoder rejected with `LineTooLong(8192)`. The encoder
  // now caps each `data:` line at 2000 codepoints, keeping every
  // emitted line under the decoder limit at the cost of inserting
  // `\n` boundaries at chunk joins (the WHATWG dispatch rule joins
  // multiple `data:` lines with LF). The round-trip therefore
  // *parses* on the receive side rather than failing outright; the
  // decoded value differs from the input by the inserted boundaries,
  // and callers that need byte-identical fidelity should base64-
  // encode payloads above this threshold.
  let payload = string.repeat("x", 10_000)
  let ev = ssevents.new(payload)
  let wire = ssevents.encode(ev)
  let assert Ok([event.EventItem(decoded)]) = ssevents.decode(wire)
  // 10_000 / 2_000 = 5 chunks → 4 inserted boundaries → length grows
  // by 4 LF characters.
  string.length(event.data_of(decoded)) |> should.equal(10_004)
}

fn contains_byte(input: BitArray, target: Int) -> Bool {
  case input {
    <<>> -> False
    <<byte, rest:bytes>> ->
      case byte == target {
        True -> True
        False -> contains_byte(rest, target)
      }
    _ -> False
  }
}
