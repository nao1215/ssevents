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
  ssevents.decode("retry: nope\n\n")
  |> should.equal(Error(InvalidRetry("nope")))
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
