//// Lightweight iterator utilities for chunk-based encode/decode flows.
////
//// The current `gleam_stdlib` version used by this repository does
//// not ship a general-purpose iterator module, so `ssevents` provides
//// a tiny local one for its own stream adapters.

import gleam/list
import ssevents/decoder
import ssevents/encoder
import ssevents/error.{type SseError}
import ssevents/event
import ssevents/limit

pub opaque type Iterator(a) {
  Iterator(next: fn() -> Step(a))
}

pub type Step(a) {
  Next(item: a, rest: Iterator(a))
  Done
}

pub fn empty() -> Iterator(a) {
  Iterator(fn() { Done })
}

pub fn single(item: a) -> Iterator(a) {
  Iterator(fn() { Next(item: item, rest: empty()) })
}

pub fn from_list(items: List(a)) -> Iterator(a) {
  Iterator(fn() {
    case items {
      [] -> Done
      [item, ..rest] -> Next(item: item, rest: from_list(rest))
    }
  })
}

pub fn next(iterator: Iterator(a)) -> Step(a) {
  iterator.next()
}

pub fn to_list(iterator: Iterator(a)) -> List(a) {
  to_list_loop(iterator, [])
}

pub fn map(over iterator: Iterator(a), with f: fn(a) -> b) -> Iterator(b) {
  Iterator(fn() {
    case next(iterator) {
      Done -> Done
      Next(item, rest) -> Next(item: f(item), rest: map(over: rest, with: f))
    }
  })
}

pub fn append(left: Iterator(a), right: Iterator(a)) -> Iterator(a) {
  Iterator(fn() {
    case next(left) {
      Done -> next(right)
      Next(item, rest) -> Next(item: item, rest: append(rest, right))
    }
  })
}

pub fn encode_stream(items: Iterator(event.Item)) -> Iterator(BitArray) {
  map(over: items, with: encoder.encode_item_bytes)
}

pub fn decode_stream(
  chunks: Iterator(BitArray),
) -> Iterator(Result(event.Item, SseError)) {
  decode_stream_with_limits(chunks, limits: limit.default())
}

pub fn decode_stream_with_limits(
  chunks: Iterator(BitArray),
  limits limits: limit.Limits,
) -> Iterator(Result(event.Item, SseError)) {
  pull_decoded(
    decoder: decoder.new_decoder_with_limits(limits),
    chunks: chunks,
    pending_rev: [],
    finished: False,
  )
}

fn to_list_loop(iterator: Iterator(a), acc_rev: List(a)) -> List(a) {
  case next(iterator) {
    Done -> list.reverse(acc_rev)
    Next(item, rest) -> to_list_loop(rest, [item, ..acc_rev])
  }
}

fn pull_decoded(
  decoder decoder_state: decoder.DecodeState,
  chunks chunks: Iterator(BitArray),
  pending_rev pending_rev: List(Result(event.Item, SseError)),
  finished finished: Bool,
) -> Iterator(Result(event.Item, SseError)) {
  Iterator(fn() { step_decoded(decoder_state, chunks, pending_rev, finished) })
}

fn step_decoded(
  decoder_state: decoder.DecodeState,
  chunks: Iterator(BitArray),
  pending_rev: List(Result(event.Item, SseError)),
  finished: Bool,
) -> Step(Result(event.Item, SseError)) {
  case pending_rev {
    [item, ..rest] ->
      Next(
        item: item,
        rest: pull_decoded(
          decoder: decoder_state,
          chunks: chunks,
          pending_rev: rest,
          finished: finished,
        ),
      )
    [] ->
      case finished {
        True -> Done
        False -> advance_decoder(decoder_state, chunks)
      }
  }
}

fn advance_decoder(
  decoder_state: decoder.DecodeState,
  chunks: Iterator(BitArray),
) -> Step(Result(event.Item, SseError)) {
  case next(chunks) {
    Next(chunk, rest_chunks) ->
      handle_push(
        decoder.push(decoder_state, chunk),
        decoder_state,
        rest_chunks,
      )
    Done -> handle_finish(decoder.finish(decoder_state), decoder_state)
  }
}

fn handle_push(
  result: Result(#(decoder.DecodeState, List(event.Item)), SseError),
  prev_decoder: decoder.DecodeState,
  rest_chunks: Iterator(BitArray),
) -> Step(Result(event.Item, SseError)) {
  case result {
    Error(error) -> terminal_error(error, prev_decoder)
    Ok(#(next_decoder, emitted)) ->
      step_decoded(
        next_decoder,
        rest_chunks,
        emitted |> list.map(Ok) |> list.reverse,
        False,
      )
  }
}

fn handle_finish(
  result: Result(List(event.Item), SseError),
  decoder_state: decoder.DecodeState,
) -> Step(Result(event.Item, SseError)) {
  case result {
    Error(error) -> terminal_error(error, decoder_state)
    Ok(emitted) ->
      step_decoded(
        decoder_state,
        empty(),
        emitted |> list.map(Ok) |> list.reverse,
        True,
      )
  }
}

fn terminal_error(
  error: SseError,
  decoder_state: decoder.DecodeState,
) -> Step(Result(event.Item, SseError)) {
  Next(
    item: Error(error),
    rest: pull_decoded(
      decoder: decoder_state,
      chunks: empty(),
      pending_rev: [],
      finished: True,
    ),
  )
}
