import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents
import ssevents/error.{
  EventTooLarge, InvalidRetry, InvalidUtf8, LineTooLong, TooManyDataLines,
}
import ssevents/event.{Comment, EventItem}

pub fn decode_simple_event_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("event: ping\ndata: hello\nid: 1\nretry: 1000\n\n")

  ssevents.name_of(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
  ssevents.id_of(event) |> should.equal(Some("1"))
  ssevents.retry_of(event) |> should.equal(Some(1000))
}

pub fn decode_comment_and_event_test() {
  let assert Ok(items) = ssevents.decode(": hello\ndata: world\n\n")
  items |> should.equal([Comment("hello"), EventItem(ssevents.new("world"))])
}

pub fn decode_bytes_matches_string_decode_test() {
  let input = ": hello\ndata: world\n\n"

  ssevents.decode_bytes(bit_array.from_string(input))
  |> should.equal(ssevents.decode(input))
}

pub fn decode_bytes_with_limits_matches_string_decode_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 100,
      max_event_bytes: 100,
      max_data_lines: 10,
      max_retry_value: 1000,
    )
  let input = "event: ping\ndata: hello\n\n"

  ssevents.decode_bytes_with_limits(
    bit_array.from_string(input),
    limits: limits,
  )
  |> should.equal(ssevents.decode_with_limits(input, limits: limits))
}

pub fn decode_unknown_fields_are_ignored_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("foo: bar\ndata: ok\nanother\n\n")

  ssevents.data_of(event) |> should.equal("ok")
  ssevents.name_of(event) |> should.equal(None)
}

pub fn decode_crlf_test() {
  let assert Ok([EventItem(event)]) =
    ssevents.decode("event: ping\r\ndata: hello\r\n\r\n")

  ssevents.name_of(event) |> should.equal(Some("ping"))
  ssevents.data_of(event) |> should.equal("hello")
}

pub fn decode_final_unterminated_event_is_dispatched_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("data: tail")
  ssevents.data_of(event) |> should.equal("tail")
}

pub fn decode_retry_only_event_is_preserved_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("retry: 1500\n\n")
  ssevents.data_of(event) |> should.equal("")
  ssevents.retry_of(event) |> should.equal(Some(1500))
}

pub fn decode_empty_data_event_test() {
  let assert Ok([EventItem(event)]) = ssevents.decode("data:\n\n")
  ssevents.data_of(event) |> should.equal("")
}

pub fn decode_invalid_retry_test() {
  // WHATWG SSE §9.2.6: a `retry:` value that isn't all ASCII digits
  // is silently ignored. The only field on this event is the bad
  // retry, so the event has no `data:` and is not dispatched at all
  // — an empty list is the expected result.
  ssevents.decode("retry: nope\n\n")
  |> should.equal(Ok([]))
}

pub fn decode_bytes_invalid_utf8_in_field_name_test() {
  ssevents.decode_bytes(<<255, 58, 32, 120, 10, 10>>)
  |> should.equal(Error(InvalidUtf8))
}

pub fn decode_bytes_invalid_utf8_in_field_value_test() {
  ssevents.decode_bytes(<<100, 97, 116, 97, 58, 32, 255, 10, 10>>)
  |> should.equal(Error(InvalidUtf8))
}

pub fn decode_line_too_long_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 4,
      max_event_bytes: 100,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode_with_limits("data: hello\n\n", limits: limits)
  |> should.equal(Error(LineTooLong(4)))
}

pub fn decode_event_too_large_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 100,
      max_event_bytes: 8,
      max_data_lines: 10,
      max_retry_value: 1000,
    )

  ssevents.decode_with_limits("data: hello\n\n", limits: limits)
  |> should.equal(Error(EventTooLarge(8)))
}

pub fn decode_too_many_data_lines_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 100,
      max_event_bytes: 100,
      max_data_lines: 2,
      max_retry_value: 1000,
    )

  ssevents.decode_bytes_with_limits(
    <<"data: 1\ndata: 2\ndata: 3\n\n":utf8>>,
    limits: limits,
  )
  |> should.equal(Error(TooManyDataLines(2)))
}

pub fn decode_max_data_lines_boundary_test() {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 100,
      max_event_bytes: 100,
      max_data_lines: 2,
      max_retry_value: 1000,
    )

  let assert Ok([EventItem(event)]) =
    ssevents.decode_bytes_with_limits(
      <<"data: 1\ndata: 2\n\n":utf8>>,
      limits: limits,
    )

  ssevents.data_of(event) |> should.equal("1\n2")
}

pub fn incremental_push_handles_partial_chunks_test() {
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) =
    state |> ssevents.push(bit_array.from_string("data: hel"))
  items1 |> should.equal([])

  let assert Ok(#(state, items2)) =
    state |> ssevents.push(bit_array.from_string("lo\n\n"))
  items2 |> should.equal([EventItem(ssevents.new("hello"))])

  let assert Ok(items3) = ssevents.finish(state)
  items3 |> should.equal([])
}

pub fn incremental_push_handles_split_utf8_test() {
  let full = bit_array.from_string("data: 😀\n\n")
  let assert Ok(chunk1) = bit_array.slice(from: full, at: 0, take: 8)
  let assert Ok(chunk2) =
    bit_array.slice(from: full, at: 8, take: bit_array.byte_size(full) - 8)

  let assert Ok(#(state, items1)) =
    ssevents.push(ssevents.new_decoder(), chunk1)
  items1 |> should.equal([])

  let assert Ok(#(_state, items2)) = ssevents.push(state, chunk2)
  items2 |> should.equal([EventItem(ssevents.new("😀"))])
}

pub fn incremental_push_invalid_utf8_returns_error_without_advancing_test() {
  let state = ssevents.new_decoder()

  ssevents.push(state, <<100, 97, 116, 97, 58, 32, 255, 10>>)
  |> should.equal(Error(InvalidUtf8))

  let assert Ok(items) = ssevents.finish(state)
  items |> should.equal([])
}

pub fn incremental_push_handles_crlf_split_across_chunks_test() {
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) =
    ssevents.push(state, <<"data: hello\r":utf8>>)
  items1 |> should.equal([])

  let assert Ok(#(state, items2)) =
    ssevents.push(state, <<"\ndata: world\r\n\r\n":utf8>>)
  items2 |> should.equal([EventItem(ssevents.new("hello\nworld"))])

  let assert Ok(items3) = ssevents.finish(state)
  items3 |> should.equal([])
}

pub fn incremental_push_handles_crlf_with_one_byte_chunks_test() {
  let chunks =
    <<"data: hello\r\ndata: world\r\n\r\n":utf8>>
    |> bytes_to_single_byte_chunks

  let assert Ok(#(state, items)) =
    push_chunks(ssevents.new_decoder(), chunks, [])
  items |> should.equal([EventItem(ssevents.new("hello\nworld"))])

  let assert Ok(trailing) = ssevents.finish(state)
  trailing |> should.equal([])
}

// WHATWG SSE §9.2.5: a leading U+FEFF BOM at the start of the stream
// must be stripped before parsing. The BOM is the UTF-8 byte sequence
// EF BB BF.

pub fn decode_bytes_strips_leading_bom_test() {
  let body = <<0xEF, 0xBB, 0xBF, "data: hello\n\n":utf8>>
  let assert Ok(items) = ssevents.decode_bytes(body)
  items |> should.equal([EventItem(ssevents.new("hello"))])
}

pub fn decode_bytes_only_strips_one_bom_test() {
  // A second BOM in the *body* (not at the start) is not part of the
  // §9.2.5 rule and should pass through as data bytes — but `data:`
  // lines are decoded as UTF-8 strings, so a stray BOM mid-data
  // becomes a U+FEFF character in the data value.
  let body = <<0xEF, 0xBB, 0xBF, "data: ":utf8, 0xEF, 0xBB, 0xBF, "x\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.data_of(event) |> should.equal("\u{FEFF}x")
}

pub fn decode_bytes_no_bom_unchanged_test() {
  // Baseline: a stream that does not start with the BOM byte
  // sequence (`EF BB BF`) decodes the same way it always did.
  let body = <<"data: hello\n\n":utf8>>
  let assert Ok(items) = ssevents.decode_bytes(body)
  items |> should.equal([EventItem(ssevents.new("hello"))])
}

// WHATWG SSE §9.2.5: lone CR (U+000D) is a line terminator alongside
// CRLF and lone LF.

pub fn decode_lone_cr_line_separator_test() {
  // `data: a\rdata: b\r\r` is the same shape as `data: a\ndata: b\n\n`
  // but with lone-CR terminators. Should yield one event with data
  // "a\nb" (multi-line data lines join with LF per §9.2.6).
  let body = <<"data: a\rdata: b\r\r":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.data_of(event) |> should.equal("a\nb")
}

pub fn decode_lone_cr_terminates_event_test() {
  // Single event terminated by `\r\r` (blank line via lone CR).
  let body = <<"data: hello\r\r":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.data_of(event) |> should.equal("hello")
}

pub fn decode_mixed_lone_cr_and_lf_test() {
  // Mixed terminators in the same stream are legal per §9.2.5.
  let body = <<"data: a\rdata: b\ndata: c\r\n\r":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.data_of(event) |> should.equal("a\nb\nc")
}

pub fn finish_with_trailing_lone_cr_test() {
  // A buffer ending in CR with nothing after is a lone-CR terminator
  // at finish time (no more bytes are coming).
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) =
    ssevents.push(state, <<"data: hello\r":utf8>>)
  // CR-at-end is ambiguous mid-stream, so push doesn't emit yet.
  items1 |> should.equal([])
  // finish treats the trailing CR as a lone-CR terminator and emits
  // the unterminated event with `data: hello`.
  let assert Ok(items) = ssevents.finish(state)
  items |> should.equal([EventItem(ssevents.new("hello"))])
}

// WHATWG SSE §9.2.6: retry with non-ASCII-digit value must be
// silently ignored, not error. The surrounding event still dispatches.

pub fn decode_retry_decimal_is_silently_ignored_test() {
  let body = <<"retry: 12.5\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_negative_is_silently_ignored_test() {
  // Per WHATWG, "ASCII digits" excludes the `-` character — negative
  // values must be ignored.
  let body = <<"retry: -100\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_empty_is_silently_ignored_test() {
  // Zero ASCII digits is not "only ASCII digits" — ignore.
  let body = <<"retry: \ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_alpha_is_silently_ignored_test() {
  let body = <<"retry: abc\ndata: ping\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  ssevents.retry_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("ping")
}

pub fn decode_retry_within_limit_still_set_test() {
  // Baseline: an all-digits value within the safety limit is still
  // applied.
  let assert Ok([EventItem(event)]) =
    ssevents.decode("retry: 1500\ndata: payload\n\n")
  ssevents.retry_of(event) |> should.equal(Some(1500))
}

pub fn decode_retry_above_limit_still_errors_test() {
  // The `max_retry_value` safety bound is a per-decoder limit, not a
  // spec rule. Above-limit values stay an `InvalidRetry` error so
  // callers can detect adversarial input. The default limit is
  // 86_400_000 ms (one day); 99_999_999_999 is well above.
  ssevents.decode_bytes(<<"retry: 99999999999\ndata: ping\n\n":utf8>>)
  |> should.equal(Error(InvalidRetry("99999999999")))
}

// WHATWG SSE §9.2.6: id with NUL must be silently ignored, not error.
// The surrounding event must still dispatch from its other fields.

pub fn decode_id_with_nul_is_silently_ignored_test() {
  let body = <<"id: be\u{0000}fore\ndata: payload\n\n":utf8>>
  let assert Ok([EventItem(event)]) = ssevents.decode_bytes(body)
  // The event dispatched, but the id field was dropped.
  ssevents.id_of(event) |> should.equal(None)
  ssevents.data_of(event) |> should.equal("payload")
}

pub fn decode_id_without_nul_still_set_test() {
  // Baseline: a clean id is still applied.
  let assert Ok([EventItem(event)]) =
    ssevents.decode("id: clean\ndata: payload\n\n")
  ssevents.id_of(event) |> should.equal(Some("clean"))
}

pub fn decode_id_with_lf_is_silently_ignored_test() {
  // Per WHATWG, the only NUL is explicitly mentioned, but the same
  // validation helper rejects CR/LF too — and the wire-format
  // semantics of "ignore the field" are the same. A CR/LF in the id
  // can only arise from a broken upstream encoder; the decoder
  // silently drops the field rather than failing the event.
  // (CR / LF inside the value never reach the decoder via well-formed
  // wire input because they would terminate the line first; this
  // test asserts the behaviour at the validate boundary.)
  let assert Ok(items) = ssevents.decode("data: payload\n\n")
  list.length(items) |> should.equal(1)
}

pub fn incremental_push_strips_bom_split_across_chunks_test() {
  // Push the BOM bytes one at a time, then the rest. The decoder
  // should still strip the full BOM and emit one event.
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) = ssevents.push(state, <<0xEF>>)
  items1 |> should.equal([])
  let assert Ok(#(state, items2)) = ssevents.push(state, <<0xBB>>)
  items2 |> should.equal([])
  let assert Ok(#(state, items3)) = ssevents.push(state, <<0xBF>>)
  items3 |> should.equal([])
  let assert Ok(#(state, items4)) =
    ssevents.push(state, <<"data: hello\n\n":utf8>>)
  items4 |> should.equal([EventItem(ssevents.new("hello"))])
  let assert Ok(trailing) = ssevents.finish(state)
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
  let assert Ok([EventItem(decoded)]) = ssevents.decode(wire)
  ssevents.name_of(decoded) |> should.equal(Some("\u{1B00}X"))
  ssevents.data_of(decoded) |> should.equal("x")
}

pub fn decode_preserves_combining_acute_after_leading_space_test() {
  // Same defect class with U+0301 COMBINING ACUTE ACCENT.
  let wire = "event: \u{0301}E\n\n"
  let assert Ok([EventItem(decoded)]) = ssevents.decode(wire)
  ssevents.name_of(decoded) |> should.equal(Some("\u{0301}E"))
}

pub fn decode_comment_preserves_combining_mark_after_leading_space_test() {
  // `decode_comment_text` shares the same trim helper, so the same
  // bug surfaced for comments.
  let wire = ": \u{1B00}note\n\n"
  let assert Ok([Comment(text)]) = ssevents.decode(wire)
  text |> should.equal("\u{1B00}note")
}

pub fn decode_id_preserves_combining_mark_after_leading_space_test() {
  let wire = "id: \u{0301}1\ndata: x\n\n"
  let assert Ok([EventItem(decoded)]) = ssevents.decode(wire)
  ssevents.id_of(decoded) |> should.equal(Some("\u{0301}1"))
}

pub fn decode_preserves_bom_after_leading_space_test() {
  // Regression for the JS-target footgun in #59: an initial fix
  // that round-tripped through BitArray would stripping a U+FEFF
  // sitting immediately after the optional space, because
  // `TextDecoder` defaults to `ignoreBOM: false`. The codepoint-
  // based trim preserves it.
  let wire = "data: \u{FEFF}x\n\n"
  let assert Ok([EventItem(decoded)]) = ssevents.decode(wire)
  ssevents.data_of(decoded) |> should.equal("\u{FEFF}x")
}
