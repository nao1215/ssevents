//// Chunk-boundary and line-ending parity tests for `ssevents`, on both
//// targets.
////
//// (I3) `encode_items` is concatenation: `encode_items(xs)` equals the
////      concatenation of `encode_items([x])` for each item.
////
//// (I4) Round trip: `decode(encode_items(xs))` equals `Ok(xs)` for every
////      corpus list `xs`.
////
//// (I5) Line-ending parity: the same wire with CRLF in place of every LF
////      decodes to the same items.
////
//// (I6) Chunk-boundary parity: feeding an encoded stream through `push`
////      in fixed-size chunks and then `finish` yields the same items as
////      `decode` on the whole input.
////
//// (I7) Every-split parity, the strong form of I6: for every split
////      position, the two-chunk feed yields the same items as `decode`.
////
//// (I8) Empty input: `decode(<<>>)` and `finish(new_decoder(_))` return
////      `Ok([])`.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/string
import gleeunit/should
import ssevents.{CommentItem, EventItem}

fn decode(text: String) -> Result(List(ssevents.Item), ssevents.SseError) {
  decode_bytes(<<text:utf8>>)
}

fn decode_bytes(
  bytes: BitArray,
) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(bytes, ssevents.default_limits)
}

fn encode_bytes(items: List(ssevents.Item)) -> BitArray {
  <<ssevents.encode_items(items):utf8>>
}

/// The same wire with every LF line ending written as CRLF. The encoder
/// writes no CR, so every LF in its output ends a line.
fn with_crlf(wire: String) -> String {
  string.replace(in: wire, each: "\n", with: "\r\n")
}

// ====== Corpus =============================================================

fn corpus() -> List(ssevents.Item) {
  [
    ssevents.comment("meta"),
    ssevents.comment(""),
    ssevents.new("") |> ssevents.EventItem,
    ssevents.new("hello") |> ssevents.EventItem,
    ssevents.new("line1\nline2") |> ssevents.EventItem,
    ssevents.new("line1\nline2\nline3") |> ssevents.EventItem,
    ssevents.named("ping", "hello") |> ssevents.EventItem,
    ssevents.named("update", "line1\nline2")
      |> ssevents.id("cursor-1")
      |> ssevents.EventItem,
    ssevents.named("update", "x")
      |> ssevents.id("abc")
      |> ssevents.retry(2500)
      |> ssevents.EventItem,
    ssevents.new("retry only")
      |> ssevents.retry(1500)
      |> ssevents.EventItem,
    ssevents.new("retry near max")
      |> ssevents.retry(86_399_999)
      |> ssevents.EventItem,
    ssevents.new("日本語") |> ssevents.EventItem,
    ssevents.new("emoji 🦊 fox") |> ssevents.EventItem,
    ssevents.new(string.repeat("abc", 100)) |> ssevents.EventItem,
    ssevents.named("payload", "a\nb")
      |> ssevents.id("x")
      |> ssevents.retry(1000)
      |> ssevents.EventItem,
  ]
}

fn small_corpus_for_split() -> List(ssevents.Item) {
  [
    ssevents.comment("hi"),
    ssevents.named("ping", "x") |> ssevents.EventItem,
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
  case feed_all(ssevents.new_decoder(ssevents.default_limits), chunks, []) {
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
    decode(ssevents.encode_items(xs))
    |> should.equal(Ok(xs))
  })
}

// (I4) Single-event round-trip via the non-list `encode` / `decode`.
pub fn roundtrip_single_event_test() {
  list.each(corpus(), fn(item) {
    case item {
      EventItem(e) -> {
        let assert Ok(decoded) = decode(ssevents.encode(e))
        decoded |> should.equal([EventItem(e)])
      }
      CommentItem(_) -> Nil
    }
  })
}

// Pre-flight: confirms a single-line comment round-trips as one Comment.
// Backs the corpus-level assumption used by (I4).
pub fn comment_only_roundtrip_test() {
  let assert Ok(decoded) =
    decode(ssevents.encode_items([ssevents.comment("hello")]))
  decoded |> should.equal([ssevents.comment("hello")])
}

// Round-trip property for #68: for every input the smart constructor
// accepts, `decode(encode([CommentItem(comment(s))])) ==
// [CommentItem(comment(s))]`. Construction-time sanitisation strips
// CR / LF / NUL, so the decoded comment compares equal to the
// re-sanitised input — even when the caller's raw string carried
// line breaks or NUL bytes.
pub fn comment_round_trip_property_corpus_test() {
  list.each(
    [
      "",
      "hello",
      "hello world",
      "with \u{1F600} emoji",
      "with newline\nin middle",
      "with CR\rin middle",
      "with CRLF\r\nin middle",
      "with NUL\u{0000}in middle",
      "leading newline\n",
      "\nleading newline",
      "all\rline\nseparators\r\nmixed",
      "ASCII only — keep verbatim",
      "日本語のコメント",
    ],
    fn(raw) {
      let item = ssevents.comment(raw)
      let assert Ok(decoded) = decode(ssevents.encode_items([item]))
      decoded |> should.equal([item])
    },
  )
}

// ====== Group B: Chunk-boundary parity (parameterised) ====================

// (I6) Chunked decode equals one-shot decode for several chunk sizes.
pub fn chunked_decode_matches_full_decode_test() {
  for_each_items(corpus(), fn(xs) {
    let bs = encode_bytes(xs)
    let total = bit_array.byte_size(bs)
    list.each(chunk_sizes(total), fn(k) {
      decode_chunked(bs, k) |> should.equal(decode_bytes(bs))
    })
  })
}

// (I6) Same parity holds when the wire form uses CRLF line endings.
pub fn chunked_decode_with_crlf_matches_full_decode_test() {
  for_each_items(corpus(), fn(xs) {
    let bs = <<with_crlf(ssevents.encode_items(xs)):utf8>>
    let total = bit_array.byte_size(bs)
    list.each(chunk_sizes(total), fn(k) {
      decode_chunked(bs, k) |> should.equal(decode_bytes(bs))
    })
  })
}

// ====== Group C: Every-split-position parity ==============================

// (I7) For every split position i in 0..len, two-chunk feed equals one-shot.
pub fn every_split_position_matches_full_decode_test() {
  let bs = encode_bytes(small_corpus_for_split())
  let expected = decode_bytes(bs)
  list.each(every_split(bs), fn(pair) {
    let #(prefix, suffix) = pair
    decode_via_chunks([prefix, suffix]) |> should.equal(expected)
  })
}

// (I7) Same property with CRLF wire form: catches splits that land
// between CR and LF.
pub fn every_split_position_with_crlf_test() {
  let bs = <<with_crlf(ssevents.encode_items(small_corpus_for_split())):utf8>>
  let expected = decode_bytes(bs)
  list.each(every_split(bs), fn(pair) {
    let #(prefix, suffix) = pair
    decode_via_chunks([prefix, suffix]) |> should.equal(expected)
  })
}

// (I7) Same property with a leading UTF-8 BOM so split positions 1, 2, 3
// land inside the BOM and exercise the partial-BOM-strip path.
pub fn every_split_position_with_bom_test() {
  let body = encode_bytes(small_corpus_for_split())
  let bs = bit_array.concat([<<0xEF, 0xBB, 0xBF>>, body])
  let expected = decode_bytes(bs)
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

// (I4 + I5) Both encodings round-trip back to the original item list.
pub fn lf_and_crlf_decode_to_corpus_test() {
  for_each_items(corpus(), fn(xs) {
    let lf = ssevents.encode_items(xs)
    decode(lf) |> should.equal(Ok(xs))
    decode(with_crlf(lf)) |> should.equal(Ok(xs))
  })
}

// ====== Group E: Encode/concat parity =====================================

// (I3)
pub fn encode_items_equals_concat_of_encode_item_test() {
  for_each_items(corpus(), fn(xs) {
    ssevents.encode_items(xs)
    |> should.equal(
      string.concat(list.map(xs, fn(x) { ssevents.encode_items([x]) })),
    )
  })
}

// ====== Group F: String/bytes mirror, empty-input =========================

// (I8)
pub fn decode_empty_input_test() {
  decode("") |> should.equal(Ok([]))
  decode_bytes(<<>>) |> should.equal(Ok([]))

  let assert Ok(items) =
    ssevents.finish(ssevents.new_decoder(ssevents.default_limits))
  items |> should.equal([])
}
