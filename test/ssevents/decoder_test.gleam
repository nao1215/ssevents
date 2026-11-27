import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{
  CommentItem, EventItem, EventTooLarge, LineTooLong, ReconnectItem,
  TooManyDataLines,
}
import support

fn decode(text: String) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(<<text:utf8>>, ssevents.default_limits)
}

pub fn decode_simple_event_test() {
  let assert Ok([EventItem(event)]) =
    decode("event: ping\ndata: hello\nid: 1\nretry: 1000\n\n")

  ssevents.name_of(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
  ssevents.id_of(event) |> should.equal(Some("1"))
  ssevents.retry_of(event) |> should.equal(Some(1000))
}

pub fn decode_comment_and_event_test() {
  let assert Ok(items) = decode(": hello\ndata: world\n\n")
  items
  |> should.equal([
    support.comment("hello"),
    EventItem(ssevents.new("world")),
  ])
}

pub fn decode_unknown_fields_are_ignored_test() {
  let assert Ok([EventItem(event)]) = decode("foo: bar\ndata: ok\nanother\n\n")

  ssevents.data_of(event) |> should.equal("ok")
  ssevents.name_of(event) |> should.equal(None)
}

pub fn decode_crlf_test() {
  let assert Ok([EventItem(event)]) =
    decode("event: ping\r\ndata: hello\r\n\r\n")

  ssevents.name_of(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
}

pub fn decode_retry_only_block_is_a_reconnect_item_test() {
  // A block without `data` dispatches no event, but its `retry` still
  // sets the reconnection time, so it is returned as a ReconnectItem.
  decode("retry: 1500\n\n")
  |> should.equal(Ok([ReconnectItem(id: None, retry: Some(1500))]))
}

pub fn decode_empty_data_event_test() {
  let assert Ok([EventItem(event)]) = decode("data:\n\n")
  ssevents.data_of(event) |> should.equal("")
}

pub fn decode_invalid_retry_test() {
  // WHATWG SSE §9.2.6: a `retry:` value that isn't all ASCII digits
  // is silently ignored. The only field on this event is the bad
  // retry, so the event has no `data:` and is not dispatched at all
  // — an empty list is the expected result.
  decode("retry: nope\n\n")
  |> should.equal(Ok([]))
}

pub fn decode_bytes_invalid_utf8_in_field_name_test() {
  // The field is named U+FFFD, which is unknown.
  ssevents.decode(<<255, 58, 32, 120, 10, 10>>, ssevents.default_limits)
  |> should.equal(Ok([]))
}

pub fn decode_bytes_invalid_utf8_in_field_value_test() {
  ssevents.decode(
    <<100, 97, 116, 97, 58, 32, 255, 10, 10>>,
    ssevents.default_limits,
  )
  |> should.equal(Ok([EventItem(ssevents.new("\u{FFFD}"))]))
}

pub fn decode_line_too_long_test() {
  let limits =
    ssevents.Limits(
      max_line_bytes: 4,
      max_event_bytes: 100,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode(<<"data: hello\n\n":utf8>>, limits)
  |> should.equal(Error(LineTooLong(4)))
}

pub fn decode_event_too_large_test() {
  let limits =
    ssevents.Limits(
      max_line_bytes: 100,
      max_event_bytes: 8,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode(<<"data: hello\n\n":utf8>>, limits)
  |> should.equal(Error(EventTooLarge(8)))
}

pub fn decode_too_many_data_lines_test() {
  let limits =
    ssevents.Limits(
      max_line_bytes: 100,
      max_event_bytes: 100,
      max_data_lines: 2,
      max_retry_value: 1000,
    )

  ssevents.decode(<<"data: 1\ndata: 2\ndata: 3\n\n":utf8>>, limits)
  |> should.equal(Error(TooManyDataLines(2)))
}

pub fn decode_max_data_lines_boundary_test() {
  let limits =
    ssevents.Limits(
      max_line_bytes: 100,
      max_event_bytes: 100,
      max_data_lines: 2,
      max_retry_value: 1000,
    )

  let assert Ok([EventItem(event)]) =
    ssevents.decode(<<"data: 1\ndata: 2\n\n":utf8>>, limits)

  ssevents.data_of(event) |> should.equal("1\n2")
}

pub fn incremental_push_handles_partial_chunks_test() {
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, items1)) =
    state |> ssevents.push(bit_array.from_string("data: hel"))
  items1 |> should.equal([])

  let assert Ok(#(state, items2)) =
    state |> ssevents.push(bit_array.from_string("lo\n\n"))
  items2 |> should.equal([EventItem(ssevents.new("hello"))])

  let items3 = ssevents.finish(state)
  items3 |> should.equal([])
}

pub fn incremental_push_handles_split_utf8_test() {
  let full = bit_array.from_string("data: 😀\n\n")
  let assert Ok(chunk1) = bit_array.slice(from: full, at: 0, take: 8)
  let assert Ok(chunk2) =
    bit_array.slice(from: full, at: 8, take: bit_array.byte_size(full) - 8)

  let assert Ok(#(state, items1)) =
    ssevents.push(ssevents.new_decoder(ssevents.default_limits), chunk1)
  items1 |> should.equal([])

  let assert Ok(#(_state, items2)) = ssevents.push(state, chunk2)
  items2 |> should.equal([EventItem(ssevents.new("😀"))])
}

pub fn incremental_push_replaces_invalid_utf8_test() {
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, [])) =
    ssevents.push(state, <<100, 97, 116, 97, 58, 32, 255, 10>>)
  let assert Ok(#(_, items)) = ssevents.push(state, <<10>>)
  items |> should.equal([EventItem(ssevents.new("\u{FFFD}"))])
}

pub fn incremental_push_handles_crlf_split_across_chunks_test() {
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, items1)) =
    ssevents.push(state, <<"data: hello\r":utf8>>)
  items1 |> should.equal([])

  let assert Ok(#(state, items2)) =
    ssevents.push(state, <<"\ndata: world\r\n\r\n":utf8>>)
  items2 |> should.equal([EventItem(ssevents.new("hello\nworld"))])

  let items3 = ssevents.finish(state)
  items3 |> should.equal([])
}

pub fn incremental_push_handles_crlf_with_one_byte_chunks_test() {
  let chunks =
    <<"data: hello\r\ndata: world\r\n\r\n":utf8>>
    |> bytes_to_single_byte_chunks

  let assert Ok(#(state, items)) =
    push_chunks(ssevents.new_decoder(ssevents.default_limits), chunks, [])
  items |> should.equal([EventItem(ssevents.new("hello\nworld"))])

  let trailing = ssevents.finish(state)
  trailing |> should.equal([])
}

// WHATWG SSE §9.2.5: a leading U+FEFF BOM at the start of the stream
// must be stripped before parsing. The BOM is the UTF-8 byte sequence
// EF BB BF.

pub fn decode_bytes_strips_leading_bom_test() {
  let body = <<0xEF, 0xBB, 0xBF, "data: hello\n\n":utf8>>
  let assert Ok(items) = ssevents.decode(body, ssevents.default_limits)
  items |> should.equal([EventItem(ssevents.new("hello"))])
}

pub fn decode_bytes_only_strips_one_bom_test() {
  // A second BOM in the *body* (not at the start) is not part of the
  // §9.2.5 rule and should pass through as data bytes — but `data:`
  // lines are decoded as UTF-8 strings, so a stray BOM mid-data
  // becomes a U+FEFF character in the data value.
  let body = <<0xEF, 0xBB, 0xBF, "data: ":utf8, 0xEF, 0xBB, 0xBF, "x\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.data_of(event) |> should.equal("\u{FEFF}x")
}

pub fn decode_bytes_no_bom_unchanged_test() {
  // Baseline: a stream that does not start with the BOM byte
  // sequence (`EF BB BF`) decodes the same way it always did.
  let body = <<"data: hello\n\n":utf8>>
  let assert Ok(items) = ssevents.decode(body, ssevents.default_limits)
  items |> should.equal([EventItem(ssevents.new("hello"))])
}

// WHATWG SSE §9.2.5: lone CR (U+000D) is a line terminator alongside
// CRLF and lone LF.

pub fn decode_lone_cr_line_separator_test() {
  // `data: a\rdata: b\r\r` is the same shape as `data: a\ndata: b\n\n`
  // but with lone-CR terminators. Should yield one event with data
  // "a\nb" (multi-line data lines join with LF per §9.2.6).
  let body = <<"data: a\rdata: b\r\r":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.data_of(event) |> should.equal("a\nb")
}

pub fn decode_lone_cr_terminates_event_test() {
  // Single event terminated by `\r\r` (blank line via lone CR).
  let body = <<"data: hello\r\r":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.data_of(event) |> should.equal("hello")
}

pub fn decode_mixed_lone_cr_and_lf_test() {
  // Mixed terminators in the same stream are legal per §9.2.5.
  let body = <<"data: a\rdata: b\ndata: c\r\n\r":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.data_of(event) |> should.equal("a\nb\nc")
}

pub fn finish_with_trailing_lone_cr_test() {
  // The CR ends the `data` line, but no blank line follows, so the event
  // is not dispatched.
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, items1)) =
    ssevents.push(state, <<"data: hello\r":utf8>>)
  items1 |> should.equal([])
  ssevents.finish(state) |> should.equal([])
}

// WHATWG SSE §9.2.6: retry with non-ASCII-digit value must be
// silently ignored, not error. The surrounding event still dispatches.

pub fn decode_retry_decimal_is_silently_ignored_test() {
  let body = <<"retry: 12.5\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_negative_is_silently_ignored_test() {
  // Per WHATWG, "ASCII digits" excludes the `-` character — negative
  // values must be ignored.
  let body = <<"retry: -100\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_empty_is_silently_ignored_test() {
  // Zero ASCII digits is not "only ASCII digits" — ignore.
  let body = <<"retry: \ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_alpha_is_silently_ignored_test() {
  let body = <<"retry: abc\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_within_limit_still_set_test() {
  // Baseline: an all-digits value within the safety limit is still
  // applied.
  let assert Ok([EventItem(event)]) = decode("retry: 1500\ndata: payload\n\n")
  ssevents.retry_of(event) |> should.equal(Some(1500))
}

pub fn decode_retry_above_limit_is_ignored_test() {
  // `max_retry_value` bounds the decoder, not the format: a larger value
  // is ignored and the event is still returned.
  let limits = ssevents.Limits(..ssevents.default_limits, max_retry_value: 1000)
  let assert Ok([EventItem(event)]) =
    ssevents.decode(<<"retry: 1001\ndata: ping\n\n":utf8>>, limits)
  ssevents.retry_of(event) |> should.equal(None)
  let assert Ok([EventItem(event)]) =
    ssevents.decode(<<"retry: 1000\ndata: ping\n\n":utf8>>, limits)
  ssevents.retry_of(event) |> should.equal(Some(1000))
}

// WHATWG SSE §9.2.6: id with NUL must be silently ignored, not error.
// The surrounding event must still dispatch from its other fields.

pub fn decode_id_with_nul_is_silently_ignored_test() {
  let body = <<"id: be\u{0000}fore\ndata: payload\n\n":utf8>>
  let assert Ok([EventItem(event)]) =
    ssevents.decode(body, ssevents.default_limits)
  // The event dispatched, but the id field was dropped.
  ssevents.id_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("payload")
}

pub fn decode_id_without_nul_still_set_test() {
  // Baseline: a clean id is still applied.
  let assert Ok([EventItem(event)]) = decode("id: clean\ndata: payload\n\n")
  ssevents.id_of(event) |> should.equal(Some("clean"))
}

pub fn incremental_push_strips_bom_split_across_chunks_test() {
  // Push the BOM bytes one at a time, then the rest. The decoder
  // should still strip the full BOM and emit one event.
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, items1)) = ssevents.push(state, <<0xEF>>)
  items1 |> should.equal([])
  let assert Ok(#(state, items2)) = ssevents.push(state, <<0xBB>>)
  items2 |> should.equal([])
  let assert Ok(#(state, items3)) = ssevents.push(state, <<0xBF>>)
  items3 |> should.equal([])
  let assert Ok(#(state, items4)) =
    ssevents.push(state, <<"data: hello\n\n":utf8>>)
  items4 |> should.equal([EventItem(ssevents.new("hello"))])
  let trailing = ssevents.finish(state)
  trailing |> should.equal([])
}

fn bytes_to_single_byte_chunks(bits: BitArray) -> List(BitArray) {
  bytes_to_single_byte_chunks_loop(bits, [])
}

fn bytes_to_single_byte_chunks_loop(
  bits: BitArray,
  acc_rev: List(BitArray),
) -> List(BitArray) {
  case bits {
    <<>> -> list.reverse(acc_rev)
    <<byte, rest:bytes>> ->
      bytes_to_single_byte_chunks_loop(rest, [<<byte>>, ..acc_rev])
    _ -> list.reverse(acc_rev)
  }
}

fn push_chunks(
  state: ssevents.DecodeState,
  chunks: List(BitArray),
  emitted_rev: List(ssevents.Item),
) -> Result(#(ssevents.DecodeState, List(ssevents.Item)), ssevents.SseError) {
  case chunks {
    [] -> Ok(#(state, list.reverse(emitted_rev)))
    [chunk, ..rest] ->
      case ssevents.push(state, chunk) {
        Error(error) -> Error(error)
        Ok(#(next_state, emitted)) ->
          push_chunks(
            next_state,
            rest,
            list.reverse(emitted) |> list.append(emitted_rev),
          )
      }
  }
}

pub fn decode_preserves_combining_mark_after_leading_space_test() {
  // Regression for #59: U+1B00 BALINESE SIGN ULU RICEM after a
  // leading space used to be dropped because
  // `string.drop_start(.., up_to: 1)` removed the whole `space +
  // combining-mark` grapheme cluster instead of the single
  // U+0020 byte.
  let wire = "event: \u{1B00}X\ndata: x\n\n"
  let assert Ok([EventItem(decoded)]) = decode(wire)
  ssevents.name_of(decoded) |> should.equal(Some("\u{1B00}X"))
  ssevents.data_of(decoded) |> should.equal("x")
}

pub fn decode_preserves_combining_acute_after_leading_space_test() {
  // Same defect class with U+0301 COMBINING ACUTE ACCENT. Pre-#87 the
  // wire could omit a `data:` line because the decoder emitted an
  // EventItem whenever any state field was set; post-#87 the WHATWG
  // dispatch rule requires a non-empty data buffer, so the test adds
  // a trailing `data: x` to keep the combining-mark assertion
  // reachable.
  let wire = "event: \u{0301}E\ndata: x\n\n"
  let assert Ok([EventItem(decoded)]) = decode(wire)
  ssevents.name_of(decoded) |> should.equal(Some("\u{0301}E"))
}

pub fn decode_comment_preserves_combining_mark_after_leading_space_test() {
  // `decode_comment_text` shares the same trim helper, so the same
  // bug surfaced for comments.
  let wire = ": \u{1B00}note\n\n"
  let assert Ok([CommentItem(c)]) = decode(wire)
  ssevents.comment_text(c) |> should.equal("\u{1B00}note")
}

pub fn decode_id_preserves_combining_mark_after_leading_space_test() {
  let wire = "id: \u{0301}1\ndata: x\n\n"
  let assert Ok([EventItem(decoded)]) = decode(wire)
  ssevents.id_of(decoded) |> should.equal(Some("\u{0301}1"))
}

pub fn decode_preserves_bom_after_leading_space_test() {
  // Regression for the JS-target footgun in #59: an initial fix
  // that round-tripped through BitArray would stripping a U+FEFF
  // sitting immediately after the optional space, because
  // `TextDecoder` defaults to `ignoreBOM: false`. The codepoint-
  // based trim preserves it.
  let wire = "data: \u{FEFF}x\n\n"
  let assert Ok([EventItem(decoded)]) = decode(wire)
  ssevents.data_of(decoded) |> should.equal("\u{FEFF}x")
}

pub fn pending_cr_does_not_count_towards_max_line_bytes_test() {
  // A chunk that ends in CR may be followed by LF, so the decoder keeps
  // the CR in its buffer. It is a line terminator either way and must not
  // push a line of exactly `max_line_bytes` over the limit.
  let limits =
    ssevents.Limits(
      max_line_bytes: 10,
      max_event_bytes: 65_536,
      max_data_lines: 1024,
      max_retry_value: 86_400_000,
    )
  let wire = "data: abcd\r\ndata: efgh\r\r\n"
  let one_shot = ssevents.decode(<<wire:utf8>>, limits)
  one_shot |> should.be_ok
  let assert Ok(#(state, first)) =
    ssevents.push(ssevents.new_decoder(limits), <<
      "data: abcd\r":utf8,
    >>)
  let assert Ok(#(state, second)) =
    ssevents.push(state, <<"\ndata: efgh\r":utf8>>)
  let assert Ok(#(state, third)) = ssevents.push(state, <<"\r\n":utf8>>)
  let rest = ssevents.finish(state)
  Ok(list.flatten([first, second, third, rest])) |> should.equal(one_shot)

  // One byte more is still rejected, with or without the pending CR.
  ssevents.push(ssevents.new_decoder(limits), <<
    "data: abcde\r":utf8,
  >>)
  |> should.equal(Error(LineTooLong(10)))
}

pub fn decode_keeps_byte_order_mark_at_start_of_later_line_test() {
  // Only the mark at the very start of the stream is skipped. A later
  // line that starts with one names the field "\u{FEFF}data", which is
  // unknown. JavaScript used to drop the mark and read a second event.
  decode("data: a\n\n\u{FEFF}data: b\n\n")
  |> should.equal(Ok([EventItem(ssevents.new("a"))]))
}

pub fn decode_keeps_byte_order_mark_right_after_colon_test() {
  // JavaScript used to drop a mark that started the field value.
  decode("data:\u{FEFF}x\n\n")
  |> should.equal(Ok([EventItem(ssevents.new("\u{FEFF}x"))]))
  decode(":\u{FEFF}note\n")
  |> should.equal(Ok([support.comment("\u{FEFF}note")]))
}

pub fn decode_keeps_nul_in_event_name_test() {
  // The event name has no NUL rule, so the NUL is part of the name.
  let assert Ok([EventItem(event)]) = decode("event: a\u{0000}b\ndata: x\n\n")
  ssevents.name_of(event) |> should.equal(Some("a\u{0000}b"))
}

pub fn decode_keeps_nul_in_data_test() {
  decode("data: a\u{0000}b\n\n")
  |> should.equal(Ok([EventItem(ssevents.new("a\u{0000}b"))]))
}

pub fn push_dispatches_event_ending_in_lone_cr_at_chunk_end_test() {
  // A CR at the end of a chunk ends the line at once. It used to wait for
  // the next chunk to see whether an LF followed, so a server that ends
  // events with CR CR had each one delivered a chunk late.
  let decoder = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(decoder, items)) =
    ssevents.push(decoder, <<"data: a\r\r":utf8>>)
  items |> should.equal([EventItem(ssevents.new("a"))])
  // The LF of a CRLF split across chunks is still one line ending.
  let assert Ok(#(decoder, items)) =
    ssevents.push(decoder, <<"data: b\r":utf8>>)
  items |> should.equal([])
  let assert Ok(#(decoder, items)) = ssevents.push(decoder, <<"\n\r\n":utf8>>)
  items |> should.equal([EventItem(ssevents.new("b"))])
  ssevents.finish(decoder) |> should.equal([])
}

pub fn decode_treats_empty_event_name_as_message_test() {
  decode("event:\ndata: x\n\n")
  |> should.equal(Ok([EventItem(ssevents.new("x"))]))
  support.named("", "x") |> should.equal(ssevents.new("x"))
}

pub fn push_keeps_blank_line_after_crlf_at_chunk_end_test() {
  // A CRLF that ends a chunk is complete, so an LF at the start of the
  // next chunk is a blank line.
  let decoder = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(decoder, [])) = ssevents.push(decoder, <<"data: a\r\n":utf8>>)
  let assert Ok(#(_, items)) = ssevents.push(decoder, <<"\n":utf8>>)
  items |> should.equal([EventItem(ssevents.new("a"))])
}

pub fn push_strips_the_byte_order_mark_only_at_the_start_of_the_stream_test() {
  // A chunk that starts with EF BB BF later in the stream is not the start
  // of the stream: the mark stays and makes the field name unknown, whether
  // the first chunk had a mark or not.
  let later = <<0xEF, 0xBB, 0xBF, "data: b\n\n":utf8>>
  [<<0xEF, 0xBB, 0xBF, "data: a\n\n":utf8>>, <<"data: a\n\n":utf8>>]
  |> list.each(fn(first) {
    let state = ssevents.new_decoder(ssevents.default_limits)
    let assert Ok(#(state, first_items)) = ssevents.push(state, first)
    let assert Ok(#(_, later_items)) = ssevents.push(state, later)
    assert #(first_items, later_items) == #([EventItem(ssevents.new("a"))], [])
  })
}

pub fn push_reads_an_lf_after_a_cr_that_ended_an_earlier_chunk_test() {
  // The LF that may follow a CR is skipped only at the start of the next
  // chunk. Here the next chunk starts with another line, so a later LF is
  // a blank line again and dispatches the event.
  let state = ssevents.new_decoder(ssevents.default_limits)
  let assert Ok(#(state, [])) = ssevents.push(state, <<"data: a\r":utf8>>)
  let assert Ok(#(state, [])) = ssevents.push(state, <<"data: b\n":utf8>>)
  let assert Ok(#(_, items)) = ssevents.push(state, <<"\n":utf8>>)
  assert items == [EventItem(ssevents.new("a\nb"))]
}
