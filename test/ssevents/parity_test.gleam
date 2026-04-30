//// Cross-target parity and chunk-boundary tests for `ssevents`.
////
//// These tests are framed as "documented invariants" so that future
//// contributors know exactly what must stay stable across releases
//// and across the Erlang and JavaScript targets. Each test function
//// is tagged with the invariant(s) it asserts.
////
//// Invariants protected by this file:
////
//// (I1) String/Bytes mirror — encode:
////      `encode_bytes(e)` equals `bit_array.from_string(encode(e))`.
////      Same for `encode_item` / `encode_item_bytes` and
////      `encode_items` / `encode_items_bytes`.
////
//// (I2) String/Bytes mirror — decode:
////      `decode_bytes(bit_array.from_string(s))` equals `decode(s)`.
////
//// (I3) `encode_items` is concatenation:
////      `encode_items(xs)` equals `string.concat(map(xs, encode_item))`,
////      and `encode_items_bytes(xs)` equals
////      `bit_array.concat(map(xs, encode_item_bytes))`. Holds for both
////      `Lf` and `Crlf` line endings.
////
//// (I4) Round-trip:
////      `decode(encode_items(xs))` equals `Ok(xs)` for every corpus
////      list `xs`. Multi-line `Comment` items are deliberately
////      excluded from the corpus because the encoder splits a
////      comment containing `\n` into multiple `:` lines, which the
////      decoder reads back as multiple `Comment` items.
////
//// (I5) Line-ending parity:
////      `decode(encode_items_with_line_ending(xs, Lf))` equals
////      `decode(encode_items_with_line_ending(xs, Crlf))`. The wire
////      bytes differ; the decoded item list does not.
////
//// (I6) Chunk-boundary parity (parameterised):
////      Feeding an encoded byte string through `push` in
////      fixed-size chunks then `finish` yields the same items as
////      `decode_bytes` on the whole input.
////
//// (I7) Every-split parity (the strong form of I6):
////      For every split position `i` in `0..byte_size(bs)`, the
////      two-chunk feed `[prefix, suffix]` followed by `finish`
////      yields the same items as `decode_bytes(bs)`. Run on a
////      small payload to keep test time bounded.
////
//// (I8) Empty-input invariant:
////      `decode("")`, `decode_bytes(<<>>)`, and
////      `finish(new_decoder())` all return `Ok([])`.
////
//// UTF-8 error-path parity and limit-error parity (LineTooLong,
//// EventTooLarge, TooManyDataLines, InvalidRetry) across targets are
//// already covered by the existing `decoder_test` and `limit_test`
//// suites; this file is focused on happy-path semantic equivalence.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import ssevents
import ssevents/encoder
import ssevents/event.{Comment, EventItem}

// ====== Corpus =============================================================

fn corpus() -> List(ssevents.Item) {
  [
    ssevents.comment("meta"),
    ssevents.comment(""),
    ssevents.new("") |> ssevents.event_item,
    ssevents.new("hello") |> ssevents.event_item,
    ssevents.new("line1\nline2") |> ssevents.event_item,
    ssevents.new("line1\nline2\nline3") |> ssevents.event_item,
    ssevents.named("ping", "hello") |> ssevents.event_item,
    ssevents.named("update", "line1\nline2")
      |> ssevents.id("cursor-1")
      |> ssevents.event_item,
    ssevents.from_parts(
      event_name: Some("update"),
      data: "x",
      id: Some("abc"),
      retry: Some(2500),
    )
      |> ssevents.event_item,
    ssevents.new("retry only")
      |> ssevents.retry(1500)
      |> ssevents.event_item,
    ssevents.new("retry near max")
      |> ssevents.retry(86_399_999)
      |> ssevents.event_item,
    ssevents.new("日本語") |> ssevents.event_item,
    ssevents.new("emoji 🦊 fox") |> ssevents.event_item,
    ssevents.new(string.repeat("abc", 100)) |> ssevents.event_item,
    ssevents.named("payload", "a\nb")
      |> ssevents.id("x")
      |> ssevents.retry(1000)
      |> ssevents.event_item,
  ]
}

fn small_corpus_for_split() -> List(ssevents.Item) {
  [
    ssevents.comment("hi"),
    ssevents.named("ping", "x") |> ssevents.event_item,
  ]
}

// ====== Helpers ============================================================

fn split_at(bytes: BitArray, at: Int) -> #(BitArray, BitArray) {
  let total = bit_array.byte_size(bytes)
  let assert Ok(prefix) = bit_array.slice(bytes, at: 0, take: at)
  let assert Ok(suffix) = bit_array.slice(bytes, at: at, take: total - at)
  #(prefix, suffix)
}

fn chunked(bytes: BitArray, size: Int) -> List(BitArray) {
  let total = bit_array.byte_size(bytes)
  case total, size <= 0 {
    0, _ -> []
    _, True -> [bytes]
    _, False -> chunked_loop(bytes, size, 0, total, [])
  }
}

fn chunked_loop(
  bytes: BitArray,
  size: Int,
  offset: Int,
  total: Int,
  acc_rev: List(BitArray),
) -> List(BitArray) {
  case offset >= total {
    True -> list.reverse(acc_rev)
    False -> {
      let remaining = total - offset
      let take = case size > remaining {
        True -> remaining
        False -> size
      }
      let assert Ok(chunk) = bit_array.slice(bytes, at: offset, take: take)
      chunked_loop(bytes, size, offset + take, total, [chunk, ..acc_rev])
    }
  }
}

fn every_split(bytes: BitArray) -> List(#(BitArray, BitArray)) {
  let total = bit_array.byte_size(bytes)
  range_inclusive(0, total)
  |> list.map(fn(i) { split_at(bytes, i) })
}

fn range_inclusive(from: Int, to: Int) -> List(Int) {
  range_loop(from, to, [])
}

fn range_loop(from: Int, to: Int, acc: List(Int)) -> List(Int) {
  use <- bool.guard(when: to < from, return: acc)
  range_loop(from, to - 1, [to, ..acc])
}

fn feed_all(
  state: ssevents.DecodeState,
  chunks: List(BitArray),
  emitted_rev: List(ssevents.Item),
) -> Result(#(ssevents.DecodeState, List(ssevents.Item)), ssevents.SseError) {
  case chunks {
    [] -> Ok(#(state, list.reverse(emitted_rev)))
    [chunk, ..rest] ->
      case ssevents.push(state, chunk) {
        Error(error) -> Error(error)
        Ok(#(next_state, items)) ->
          feed_all(
            next_state,
            rest,
            list.reverse(items) |> list.append(emitted_rev),
          )
      }
  }
}

fn decode_via_chunks(
  chunks: List(BitArray),
) -> Result(List(ssevents.Item), ssevents.SseError) {
  case feed_all(ssevents.new_decoder(), chunks, []) {
    Error(error) -> Error(error)
    Ok(#(state, items)) ->
      case ssevents.finish(state) {
        Error(error) -> Error(error)
        Ok(trailing) -> Ok(list.append(items, trailing))
      }
  }
}

fn decode_chunked(
  bytes: BitArray,
  size: Int,
) -> Result(List(ssevents.Item), ssevents.SseError) {
  decode_via_chunks(chunked(bytes, size))
}

fn chunk_sizes(len: Int) -> List(Int) {
  [1, 2, 3, 5, 7, 13, len / 2, len / 3]
  |> list.filter(fn(n) { n >= 1 })
  |> list.unique
}

fn for_each_items(
  items: List(ssevents.Item),
  assertion: fn(List(ssevents.Item)) -> Nil,
) -> Nil {
  list.each(items, fn(item) { assertion([item]) })
  assertion(items)
}

// ====== Group A: Round-trip parity (corpus-based) =========================

// (I4)
pub fn roundtrip_decode_encode_items_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.decode(ssevents.encode_items(xs))
    |> should.equal(Ok(xs))
  })
}

// (I1, I2)
pub fn roundtrip_bytes_matches_string_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.decode_bytes(ssevents.encode_items_bytes(xs))
    |> should.equal(ssevents.decode(ssevents.encode_items(xs)))
  })
}

// (I1)
pub fn encode_items_bytes_equals_from_string_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.encode_items_bytes(xs)
    |> should.equal(bit_array.from_string(ssevents.encode_items(xs)))
  })
}

// (I2)
pub fn decode_bytes_equals_decode_string_test() {
  for_each_items(corpus(), fn(xs) {
    let encoded = ssevents.encode_items(xs)
    ssevents.decode_bytes(bit_array.from_string(encoded))
    |> should.equal(ssevents.decode(encoded))
  })
}

// (I4) Single-event round-trip via the non-list `encode` / `decode`.
pub fn roundtrip_single_event_test() {
  list.each(corpus(), fn(item) {
    case item {
      EventItem(e) -> {
        let assert Ok(decoded) = ssevents.decode(ssevents.encode(e))
        decoded |> should.equal([EventItem(e)])
      }
      Comment(_) -> Nil
    }
  })
}

// (I1) Single-event variant of the bytes-mirror property.
pub fn encode_bytes_equals_from_string_for_event_test() {
  list.each(corpus(), fn(item) {
    case item {
      EventItem(e) ->
        ssevents.encode_bytes(e)
        |> should.equal(bit_array.from_string(ssevents.encode(e)))
      Comment(_) -> Nil
    }
  })
}

// Pre-flight: confirms a single-line comment round-trips as one Comment.
// Backs the corpus-level assumption used by (I4).
pub fn comment_only_roundtrip_test() {
  let assert Ok(decoded) =
    ssevents.decode(ssevents.encode_item(Comment("hello")))
  decoded |> should.equal([Comment("hello")])
}

// ====== Group B: Chunk-boundary parity (parameterised) ====================

// (I6) Chunked decode equals one-shot decode for several chunk sizes.
pub fn chunked_decode_matches_full_decode_test() {
  for_each_items(corpus(), fn(xs) {
    let bs = ssevents.encode_items_bytes(xs)
    let total = bit_array.byte_size(bs)
    list.each(chunk_sizes(total), fn(k) {
      decode_chunked(bs, k) |> should.equal(ssevents.decode_bytes(bs))
    })
  })
}

// (I6) Same parity holds when the wire form uses CRLF line endings.
pub fn chunked_decode_with_crlf_matches_full_decode_test() {
  for_each_items(corpus(), fn(xs) {
    let encoded = ssevents.encode_items_with_line_ending(xs, encoder.Crlf)
    let bs = bit_array.from_string(encoded)
    let total = bit_array.byte_size(bs)
    list.each(chunk_sizes(total), fn(k) {
      decode_chunked(bs, k) |> should.equal(ssevents.decode_bytes(bs))
    })
  })
}

// ====== Group C: Every-split-position parity ==============================

// (I7) For every split position i in 0..len, two-chunk feed equals one-shot.
pub fn every_split_position_matches_full_decode_test() {
  let bs = ssevents.encode_items_bytes(small_corpus_for_split())
  let expected = ssevents.decode_bytes(bs)
  list.each(every_split(bs), fn(pair) {
    let #(prefix, suffix) = pair
    decode_via_chunks([prefix, suffix]) |> should.equal(expected)
  })
}

// (I7) Same property with CRLF wire form: catches splits that land
// between CR and LF.
pub fn every_split_position_with_crlf_test() {
  let encoded =
    ssevents.encode_items_with_line_ending(
      small_corpus_for_split(),
      encoder.Crlf,
    )
  let bs = bit_array.from_string(encoded)
  let expected = ssevents.decode_bytes(bs)
  list.each(every_split(bs), fn(pair) {
    let #(prefix, suffix) = pair
    decode_via_chunks([prefix, suffix]) |> should.equal(expected)
  })
}

// (I7) Same property with a leading UTF-8 BOM so split positions 1, 2, 3
// land inside the BOM and exercise the partial-BOM-strip path.
pub fn every_split_position_with_bom_test() {
  let body = ssevents.encode_items_bytes(small_corpus_for_split())
  let bs = bit_array.concat([<<0xEF, 0xBB, 0xBF>>, body])
  let expected = ssevents.decode_bytes(bs)
  list.each(every_split(bs), fn(pair) {
    let #(prefix, suffix) = pair
    decode_via_chunks([prefix, suffix]) |> should.equal(expected)
  })
}

// An empty BitArray fed in the middle of the stream is a valid no-op.
pub fn push_with_empty_chunk_in_middle_test() {
  let chunks = [<<"data: ":utf8>>, <<>>, <<"x\n\n":utf8>>]
  decode_via_chunks(chunks)
  |> should.equal(Ok([EventItem(ssevents.new("x"))]))
}

// ====== Group D: Line-ending parity =======================================

// (I5)
pub fn lf_and_crlf_decode_to_same_items_test() {
  for_each_items(corpus(), fn(xs) {
    let lf = ssevents.encode_items_with_line_ending(xs, encoder.Lf)
    let crlf = ssevents.encode_items_with_line_ending(xs, encoder.Crlf)
    ssevents.decode(lf) |> should.equal(ssevents.decode(crlf))
  })
}

// (I4 + I5) Both encodings round-trip back to the original item list.
pub fn lf_and_crlf_decode_to_corpus_test() {
  for_each_items(corpus(), fn(xs) {
    let lf = ssevents.encode_items_with_line_ending(xs, encoder.Lf)
    let crlf = ssevents.encode_items_with_line_ending(xs, encoder.Crlf)
    ssevents.decode(lf) |> should.equal(Ok(xs))
    ssevents.decode(crlf) |> should.equal(Ok(xs))
  })
}

// ====== Group E: Encode/concat parity =====================================

// (I3)
pub fn encode_items_equals_concat_of_encode_item_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.encode_items(xs)
    |> should.equal(string.concat(list.map(xs, ssevents.encode_item)))
  })
}

// (I3)
pub fn encode_items_bytes_equals_concat_of_item_bytes_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.encode_items_bytes(xs)
    |> should.equal(bit_array.concat(list.map(xs, ssevents.encode_item_bytes)))
  })
}

// (I3) Same parity for both Lf and Crlf line endings.
pub fn encode_items_with_line_ending_concat_parity_test() {
  for_each_items(corpus(), fn(xs) {
    let lf =
      string.concat(
        list.map(xs, fn(item) {
          ssevents.encode_item_with_line_ending(item, encoder.Lf)
        }),
      )
    ssevents.encode_items_with_line_ending(xs, encoder.Lf)
    |> should.equal(lf)

    let crlf =
      string.concat(
        list.map(xs, fn(item) {
          ssevents.encode_item_with_line_ending(item, encoder.Crlf)
        }),
      )
    ssevents.encode_items_with_line_ending(xs, encoder.Crlf)
    |> should.equal(crlf)
  })
}

// ====== Group F: String/bytes mirror, empty-input =========================

// (I2) Property restatement of decode_bytes_equals_decode_string_test.
pub fn decode_bytes_mirrors_decode_for_corpus_test() {
  for_each_items(corpus(), fn(xs) {
    let encoded = ssevents.encode_items(xs)
    ssevents.decode_bytes(bit_array.from_string(encoded))
    |> should.equal(ssevents.decode(encoded))
  })
}

// (I8)
pub fn decode_empty_input_test() {
  ssevents.decode("") |> should.equal(Ok([]))
  ssevents.decode_bytes(<<>>) |> should.equal(Ok([]))

  let assert Ok(items) = ssevents.finish(ssevents.new_decoder())
  items |> should.equal([])
}
