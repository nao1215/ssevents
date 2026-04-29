//// Full-body and incremental SSE decoding.
////
//// Semantics chosen for the initial release:
//// - accepted line endings: LF and CRLF
//// - unknown fields are ignored
//// - EOF dispatches the final unterminated event or trailing comment
//// - the first decode error fails the whole operation
//// - retry values must be ASCII digits and must not exceed
////   `Limits.max_retry_value`

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import ssevents/error.{
  type SseError, EventTooLarge, InvalidRetry, InvalidUtf8, LineTooLong,
  TooManyDataLines, UnexpectedEnd,
}
import ssevents/event
import ssevents/limit
import ssevents/validate

pub opaque type DecodeState {
  DecodeState(
    buffer: BitArray,
    event_name: Option(String),
    data_lines_rev: List(String),
    data_line_count: Int,
    id: Option(String),
    retry: Option(Int),
    event_bytes: Int,
    limits: limit.Limits,
    /// True once the leading-BOM check has run for this stream.
    /// WHATWG SSE §9.2.5 requires a single U+FEFF at the start of
    /// the stream to be discarded; once we've either stripped it
    /// or established the stream doesn't start with one, this
    /// flag is set so the check doesn't repeat on later pushes.
    bom_handled: Bool,
  )
}

pub fn decode(input: String) -> Result(List(event.Item), SseError) {
  decode_with_limits(input, limits: limit.default())
}

pub fn decode_bytes(input: BitArray) -> Result(List(event.Item), SseError) {
  decode_bytes_with_limits(input, limits: limit.default())
}

pub fn decode_with_limits(
  input: String,
  limits limits: limit.Limits,
) -> Result(List(event.Item), SseError) {
  decode_bytes_with_limits(bit_array.from_string(input), limits: limits)
}

pub fn decode_bytes_with_limits(
  input: BitArray,
  limits limits: limit.Limits,
) -> Result(List(event.Item), SseError) {
  case push(new_decoder_with_limits(limits), input) {
    Error(error) -> Error(error)
    Ok(#(state, items)) ->
      case finish(state) {
        Error(error) -> Error(error)
        Ok(trailing) -> Ok(list.append(items, trailing))
      }
  }
}

pub fn new_decoder() -> DecodeState {
  new_decoder_with_limits(limit.default())
}

pub fn new_decoder_with_limits(limits: limit.Limits) -> DecodeState {
  DecodeState(
    buffer: <<>>,
    event_name: None,
    data_lines_rev: [],
    data_line_count: 0,
    id: None,
    retry: None,
    event_bytes: 0,
    limits: limits,
    bom_handled: False,
  )
}

pub fn push(
  state: DecodeState,
  chunk: BitArray,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  let combined = bit_array.append(to: state.buffer, suffix: chunk)
  let state = DecodeState(..state, buffer: combined) |> maybe_strip_bom
  process_lines(state, [])
}

/// WHATWG SSE §9.2.5: discard a leading U+FEFF BYTE ORDER MARK at the
/// very start of the stream.
///
/// `state.bom_handled` is set once we've either stripped the BOM or
/// established the stream doesn't start with one. While the buffer
/// holds only a 1- or 2-byte prefix of the BOM (`EF` or `EF BB`), we
/// hold off on deciding so the check stays correct even when the BOM
/// is split across two `push` calls.
fn maybe_strip_bom(state: DecodeState) -> DecodeState {
  case state.bom_handled, state.buffer {
    True, _ -> state
    False, <<0xEF, 0xBB, 0xBF, rest:bytes>> ->
      DecodeState(..state, buffer: rest, bom_handled: True)
    // Buffer holds a 1- or 2-byte prefix of the BOM; wait for more.
    False, <<0xEF, 0xBB>> -> state
    False, <<0xEF>> -> state
    False, <<>> -> state
    // Anything else: not a BOM-prefixed stream, never check again.
    False, _ -> DecodeState(..state, bom_handled: True)
  }
}

pub fn finish(state: DecodeState) -> Result(List(event.Item), SseError) {
  case state.buffer {
    <<>> -> finish_event(state)
    _ ->
      case ends_with_cr(state.buffer) {
        True -> Error(UnexpectedEnd)
        False ->
          case decode_line(state.buffer) {
            Error(error) -> Error(error)
            Ok(line) ->
              case
                process_line(
                  DecodeState(..state, buffer: <<>>),
                  line,
                  bit_array.byte_size(state.buffer),
                )
              {
                Error(error) -> Error(error)
                Ok(#(state_after_line, emitted)) ->
                  case finish_event(state_after_line) {
                    Error(error) -> Error(error)
                    Ok(trailing) -> Ok(list.append(emitted, trailing))
                  }
              }
          }
      }
  }
}

fn process_lines(
  state: DecodeState,
  emitted_rev: List(event.Item),
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  case next_complete_line(state.buffer) {
    Ok(Some(#(line_bytes, rest, line_byte_size))) ->
      case line_byte_size > limit.max_line_bytes(state.limits) {
        True -> Error(LineTooLong(limit.max_line_bytes(state.limits)))
        False ->
          case decode_line(line_bytes) {
            Error(error) -> Error(error)
            Ok(line) ->
              case
                process_line(
                  DecodeState(..state, buffer: rest),
                  line,
                  line_byte_size,
                )
              {
                Error(error) -> Error(error)
                Ok(#(next_state, emitted)) ->
                  process_lines(
                    next_state,
                    list.reverse(emitted) |> list.append(emitted_rev),
                  )
              }
          }
      }

    Ok(None) ->
      case
        bit_array.byte_size(state.buffer) > limit.max_line_bytes(state.limits)
      {
        True -> Error(LineTooLong(limit.max_line_bytes(state.limits)))
        False -> Ok(#(state, list.reverse(emitted_rev)))
      }

    Error(error) -> Error(error)
  }
}

fn process_line(
  state: DecodeState,
  line: String,
  line_byte_size: Int,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  case line {
    "" ->
      case dispatch_event(state) {
        Error(error) -> Error(error)
        Ok(#(next_state, maybe_item)) ->
          case maybe_item {
            Some(item) -> Ok(#(next_state, [item]))
            None -> Ok(#(next_state, []))
          }
      }

    _ ->
      case string.starts_with(line, ":") {
        True ->
          Ok(
            #(state, [
              event.Comment(
                decode_comment_text(string.drop_start(from: line, up_to: 1)),
              ),
            ]),
          )

        False -> apply_field(state, line, line_byte_size)
      }
  }
}

fn apply_field(
  state: DecodeState,
  line: String,
  line_byte_size: Int,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  case split_field(line) {
    Error(error) -> Error(error)
    Ok(#(field, value)) ->
      apply_field_parts(state, field, value, line_byte_size)
  }
}

fn apply_field_parts(
  state: DecodeState,
  field: String,
  value: String,
  line_byte_size: Int,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  let next_event_bytes = state.event_bytes + line_byte_size

  case next_event_bytes > limit.max_event_bytes(state.limits) {
    True -> Error(EventTooLarge(limit.max_event_bytes(state.limits)))
    False ->
      case field {
        "data" -> apply_data_field(state, value, next_event_bytes)
        "event" ->
          apply_validated_field(
            state,
            validate.validate_event_name(value),
            next_event_bytes,
            fn(s, v) { DecodeState(..s, event_name: Some(v)) },
          )
        "id" ->
          apply_validated_field(
            state,
            validate.validate_id(value),
            next_event_bytes,
            fn(s, v) { DecodeState(..s, id: Some(v)) },
          )
        "retry" ->
          apply_validated_field(
            state,
            parse_retry(value, state.limits),
            next_event_bytes,
            fn(s, v) { DecodeState(..s, retry: Some(v)) },
          )
        _ -> Ok(#(DecodeState(..state, event_bytes: next_event_bytes), []))
      }
  }
}

fn apply_data_field(
  state: DecodeState,
  value: String,
  next_event_bytes: Int,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  case state.data_line_count + 1 > limit.max_data_lines(state.limits) {
    True -> Error(TooManyDataLines(limit.max_data_lines(state.limits)))
    False ->
      Ok(
        #(
          DecodeState(
            ..state,
            data_lines_rev: [value, ..state.data_lines_rev],
            data_line_count: state.data_line_count + 1,
            event_bytes: next_event_bytes,
          ),
          [],
        ),
      )
  }
}

fn apply_validated_field(
  state: DecodeState,
  validated: Result(a, SseError),
  next_event_bytes: Int,
  set: fn(DecodeState, a) -> DecodeState,
) -> Result(#(DecodeState, List(event.Item)), SseError) {
  case validated {
    Error(error) -> Error(error)
    Ok(value) ->
      Ok(#(set(DecodeState(..state, event_bytes: next_event_bytes), value), []))
  }
}

fn dispatch_event(
  state: DecodeState,
) -> Result(#(DecodeState, Option(event.Item)), SseError) {
  let emitted = case has_meaningful_event_content(state) {
    True ->
      Some(
        event.from_parts(
          event_name: state.event_name,
          data: state.data_lines_rev |> list.reverse |> string.join(with: "\n"),
          id: state.id,
          retry: state.retry,
        )
        |> event.event_item,
      )
    False -> None
  }

  Ok(#(reset_event_state(state), emitted))
}

fn finish_event(state: DecodeState) -> Result(List(event.Item), SseError) {
  case dispatch_event(state) {
    Error(error) -> Error(error)
    Ok(#(_, maybe_item)) ->
      case maybe_item {
        Some(item) -> Ok([item])
        None -> Ok([])
      }
  }
}

fn reset_event_state(state: DecodeState) -> DecodeState {
  DecodeState(
    ..state,
    event_name: None,
    data_lines_rev: [],
    data_line_count: 0,
    id: None,
    retry: None,
    event_bytes: 0,
  )
}

fn has_meaningful_event_content(state: DecodeState) -> Bool {
  case state.data_line_count > 0 {
    True -> True
    False ->
      case state.event_name, state.id, state.retry {
        Some(_), _, _ -> True
        _, Some(_), _ -> True
        _, _, Some(_) -> True
        None, None, None -> False
      }
  }
}

fn split_field(line: String) -> Result(#(String, String), SseError) {
  split_field_bytes(bit_array.from_string(line), <<>>, line)
}

fn split_field_bytes(
  remaining: BitArray,
  field_rev: BitArray,
  fallback: String,
) -> Result(#(String, String), SseError) {
  case remaining {
    <<>> -> Ok(#(fallback, ""))
    <<58, rest:bytes>> ->
      case bit_array.to_string(reverse_bytes(field_rev, <<>>)) {
        Error(_) -> Error(InvalidUtf8)
        Ok(field) ->
          case bit_array.to_string(rest) {
            Error(_) -> Error(InvalidUtf8)
            Ok(value) -> Ok(#(field, trim_optional_leading_space(value)))
          }
      }
    <<byte, rest:bytes>> ->
      split_field_bytes(rest, <<byte, field_rev:bits>>, fallback)
    _ -> Error(InvalidUtf8)
  }
}

fn trim_optional_leading_space(value: String) -> String {
  case string.starts_with(value, " ") {
    True -> string.drop_start(from: value, up_to: 1)
    False -> value
  }
}

fn decode_comment_text(value: String) -> String {
  trim_optional_leading_space(value)
}

fn parse_retry(value: String, limits: limit.Limits) -> Result(Int, SseError) {
  case is_ascii_digit_string(value) {
    False -> Error(InvalidRetry(value))
    True ->
      case int.parse(value) {
        Error(_) -> Error(InvalidRetry(value))
        Ok(parsed) ->
          case parsed > limit.max_retry_value(limits) {
            True -> Error(InvalidRetry(value))
            False -> Ok(parsed)
          }
      }
  }
}

fn is_ascii_digit_string(value: String) -> Bool {
  case value {
    "" -> False
    _ -> ascii_digits_only(bit_array.from_string(value))
  }
}

fn ascii_digits_only(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<digit, rest:bytes>> if digit >= 48 && digit <= 57 ->
      ascii_digits_only(rest)
    _ -> False
  }
}

fn decode_line(line: BitArray) -> Result(String, SseError) {
  case bit_array.to_string(line) {
    Ok(text) -> Ok(text)
    Error(_) -> Error(InvalidUtf8)
  }
}

fn next_complete_line(
  buffer: BitArray,
) -> Result(Option(#(BitArray, BitArray, Int)), SseError) {
  find_newline(buffer, <<>>, 0)
}

fn find_newline(
  remaining: BitArray,
  acc_rev: BitArray,
  line_bytes: Int,
) -> Result(Option(#(BitArray, BitArray, Int)), SseError) {
  case remaining {
    <<>> -> Ok(None)

    <<10, rest:bytes>> ->
      case acc_rev {
        <<13, acc_rest:bits>> ->
          Ok(Some(#(reverse_bytes(acc_rest, <<>>), rest, line_bytes - 1)))
        _ -> Ok(Some(#(reverse_bytes(acc_rev, <<>>), rest, line_bytes)))
      }

    <<byte, rest:bytes>> ->
      find_newline(rest, <<byte, acc_rev:bits>>, line_bytes + 1)

    _ -> Error(InvalidUtf8)
  }
}

fn reverse_bytes(input: BitArray, acc: BitArray) -> BitArray {
  case input {
    <<>> -> acc
    <<byte, rest:bytes>> -> reverse_bytes(rest, <<byte, acc:bits>>)
    _ -> acc
  }
}

fn ends_with_cr(bits: BitArray) -> Bool {
  let size = bit_array.byte_size(bits)
  case size {
    0 -> False
    _ -> bit_array.slice(bits, at: size - 1, take: 1) == Ok(<<13>>)
  }
}
