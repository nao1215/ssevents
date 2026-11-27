//// A differential test against a reference decoder written straight from
//// "Interpreting an event stream" in the WHATWG HTML standard, and
//// metamorphic tests on how the input is cut into chunks.
////
//// The reference decodes the whole stream to code points first, with the
//// byte-at-a-time UTF-8 decoder of the WHATWG Encoding standard, then
//// splits lines and runs the field rules on code points. `ssevents`
//// splits lines on bytes and decodes each line, so the two only agree if
//// both follow the standard. The input mixes the field names in every
//// case, colons, spaces, NUL, the three line endings, a byte order mark
//// and bytes that are not UTF-8.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import metamon
import metamon/generator.{type Generator}
import ssevents.{EventItem, ReconnectItem}
import support

// The reference ---------------------------------------------------------------

type Block {
  Block(
    data: List(String),
    name: String,
    id: Option(String),
    retry: Option(Int),
  )
}

const empty_block = Block(data: [], name: "", id: None, retry: None)

fn reference(bytes: BitArray) -> List(ssevents.Item) {
  // "The stream must then be parsed by reading everything line by line"
  // after the UTF-8 decode, which skips one leading byte order mark.
  let bytes = case bytes {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> rest
    _ -> bytes
  }
  let #(lines, _unterminated) = split_lines(utf8_decode(bytes), [], [])
  let #(block, items) =
    list.fold(lines, #(empty_block, []), fn(acc, line) {
      let #(block, items) = acc
      process_line(line, block, items)
    })
  // "Once the end of the file is reached, any pending data must be
  // discarded." The retry was already applied when its line was read.
  let tail = case block.retry {
    Some(retry) -> [ReconnectItem(id: None, retry: Some(retry))]
    None -> []
  }
  list.append(list.reverse(items), tail)
}

fn process_line(
  line: List(Int),
  block: Block,
  items: List(ssevents.Item),
) -> #(Block, List(ssevents.Item)) {
  case line {
    [] -> #(empty_block, dispatch(block, items))
    [0x3A, ..text] -> #(block, [
      support.comment(text_of(drop_space(text))),
      ..items
    ])
    _ -> {
      let #(field, value) = case list.split_while(line, fn(c) { c != 0x3A }) {
        #(field, [0x3A, ..value]) -> #(field, drop_space(value))
        #(field, _) -> #(field, [])
      }
      #(process_field(text_of(field), value, block), items)
    }
  }
}

fn process_field(field: String, value: List(Int), block: Block) -> Block {
  case field {
    "event" -> Block(..block, name: text_of(value))
    "data" -> Block(..block, data: [text_of(value), ..block.data])
    "id" ->
      case list.contains(value, 0) {
        True -> block
        False -> Block(..block, id: Some(text_of(value)))
      }
    "retry" ->
      case value != [] && list.all(value, fn(c) { c >= 0x30 && c <= 0x39 }) {
        True -> {
          let assert Ok(ms) = int.parse(text_of(value))
          case ms <= ssevents.default_limits.max_retry_value {
            True -> Block(..block, retry: Some(ms))
            False -> block
          }
        }
        False -> block
      }
    _ -> block
  }
}

fn dispatch(block: Block, items: List(ssevents.Item)) -> List(ssevents.Item) {
  case block {
    Block(data: [], id: None, retry: None, ..) -> items
    Block(data: [], id:, retry:, ..) -> [ReconnectItem(id:, retry:), ..items]
    Block(data:, name:, id:, retry:) -> {
      // Each `data` line adds its value and an LF, and the last LF is
      // removed, which is joining the lines with LF.
      let event = support.named(name, string.join(list.reverse(data), "\n"))
      let event = case id {
        Some(id) -> support.id(event, id)
        None -> event
      }
      let event = case retry {
        Some(retry) -> ssevents.retry(event, retry)
        None -> event
      }
      [EventItem(event), ..items]
    }
  }
}

fn drop_space(value: List(Int)) -> List(Int) {
  case value {
    [0x20, ..rest] -> rest
    _ -> value
  }
}

fn text_of(code_points: List(Int)) -> String {
  code_points
  |> list.filter_map(string.utf_codepoint)
  |> string.from_utf_codepoints
}

// CRLF, a lone LF and a lone CR end a line. The last line has no line
// ending if `current` is not empty.
fn split_lines(
  code_points: List(Int),
  current: List(Int),
  lines: List(List(Int)),
) -> #(List(List(Int)), List(Int)) {
  case code_points {
    [] -> #(list.reverse(lines), current)
    [0x0D, 0x0A, ..rest] | [0x0D, ..rest] | [0x0A, ..rest] ->
      split_lines(rest, [], [list.reverse(current), ..lines])
    [c, ..rest] -> split_lines(rest, [c, ..current], lines)
  }
}

// The UTF-8 decoder of https://encoding.spec.whatwg.org/#utf-8-decoder,
// one byte at a time.
fn utf8_decode(bytes: BitArray) -> List(Int) {
  utf8_loop(bytes, 0, 0, 0, 0x80, 0xBF, [])
}

fn utf8_loop(
  bytes: BitArray,
  code_point: Int,
  needed: Int,
  seen: Int,
  lower: Int,
  upper: Int,
  out: List(Int),
) -> List(Int) {
  case bytes, needed {
    <<>>, 0 -> list.reverse(out)
    <<>>, _ -> list.reverse([0xFFFD, ..out])
    <<byte, rest:bytes>>, 0 ->
      case byte {
        _ if byte <= 0x7F -> utf8_loop(rest, 0, 0, 0, 0x80, 0xBF, [byte, ..out])
        _ if byte >= 0xC2 && byte <= 0xDF ->
          utf8_loop(rest, int.bitwise_and(byte, 0x1F), 1, 0, 0x80, 0xBF, out)
        _ if byte >= 0xE0 && byte <= 0xEF -> {
          let lower = case byte {
            0xE0 -> 0xA0
            _ -> 0x80
          }
          let upper = case byte {
            0xED -> 0x9F
            _ -> 0xBF
          }
          utf8_loop(rest, int.bitwise_and(byte, 0xF), 2, 0, lower, upper, out)
        }
        _ if byte >= 0xF0 && byte <= 0xF4 -> {
          let lower = case byte {
            0xF0 -> 0x90
            _ -> 0x80
          }
          let upper = case byte {
            0xF4 -> 0x8F
            _ -> 0xBF
          }
          utf8_loop(rest, int.bitwise_and(byte, 0x7), 3, 0, lower, upper, out)
        }
        _ -> utf8_loop(rest, 0, 0, 0, 0x80, 0xBF, [0xFFFD, ..out])
      }
    <<byte, rest:bytes>>, _ ->
      case byte >= lower && byte <= upper {
        // The byte is read again as the start of the next sequence.
        False -> utf8_loop(bytes, 0, 0, 0, 0x80, 0xBF, [0xFFFD, ..out])
        True -> {
          let code_point =
            int.bitwise_or(
              int.bitwise_shift_left(code_point, 6),
              int.bitwise_and(byte, 0x3F),
            )
          case seen + 1 == needed {
            True -> utf8_loop(rest, 0, 0, 0, 0x80, 0xBF, [code_point, ..out])
            False ->
              utf8_loop(rest, code_point, needed, seen + 1, 0x80, 0xBF, out)
          }
        }
      }
    _, _ -> list.reverse(out)
  }
}

// Generators ------------------------------------------------------------------

fn piece_gen() -> Generator(BitArray) {
  generator.element_of([
    <<"data":utf8>>,
    <<"Data":utf8>>,
    <<"data ":utf8>>,
    <<"event":utf8>>,
    <<"id":utf8>>,
    <<"retry":utf8>>,
    <<"other":utf8>>,
    <<":":utf8>>,
    <<" ":utf8>>,
    <<"a":utf8>>,
    <<"7":utf8>>,
    <<"86400001":utf8>>,
    <<"\u{0000}":utf8>>,
    <<"\u{00E9}":utf8>>,
    <<"\u{1F98A}":utf8>>,
    <<0xEF, 0xBB, 0xBF>>,
    <<0xFF>>,
    <<0xC3>>,
    <<0xE2, 0x82>>,
    <<0xED, 0xA0, 0x80>>,
    <<0xF0, 0x9F, 0x98>>,
    <<0xC0, 0xAF>>,
    <<0x80>>,
    <<0xDF, 0xBF>>,
    <<0xE0, 0x9F>>,
    <<0xF4, 0x8F, 0xBF, 0xBF>>,
    <<0xF4, 0x90>>,
    <<"\n":utf8>>,
    <<"\r":utf8>>,
    <<"\r\n":utf8>>,
    <<"\n\n":utf8>>,
  ])
}

fn wire_gen() -> Generator(BitArray) {
  generator.tuple2(
    generator.bool(),
    generator.list_of(piece_gen(), generator.range(from: 0, to: 40)),
  )
  |> generator.map(fn(input) {
    let #(bom, pieces) = input
    let body = bit_array.concat(pieces)
    case bom {
      True -> <<0xEF, 0xBB, 0xBF, body:bits>>
      False -> body
    }
  })
}

fn sizes_gen() -> Generator(List(Int)) {
  generator.list_of(
    generator.int(generator.range(from: 1, to: 7)),
    generator.range(from: 1, to: 4),
  )
}

fn decode(bytes: BitArray) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(bytes, ssevents.default_limits)
}

fn decode_in_chunks(
  bytes: BitArray,
  sizes: List(Int),
) -> Result(List(ssevents.Item), ssevents.SseError) {
  push_chunks(
    ssevents.new_decoder(ssevents.default_limits),
    bytes,
    sizes,
    sizes,
    [],
  )
}

fn push_chunks(
  decoder: ssevents.DecodeState,
  bytes: BitArray,
  sizes: List(Int),
  all: List(Int),
  items: List(List(ssevents.Item)),
) -> Result(List(ssevents.Item), ssevents.SseError) {
  let total = bit_array.byte_size(bytes)
  case total, sizes {
    0, _ -> Ok(list.flatten(list.reverse([ssevents.finish(decoder), ..items])))
    _, [] -> push_chunks(decoder, bytes, all, all, items)
    _, [size, ..sizes] -> {
      let size = int.min(size, total)
      let assert Ok(chunk) = bit_array.slice(bytes, 0, size)
      let assert Ok(rest) = bit_array.slice(bytes, size, total - size)
      case ssevents.push(decoder, chunk) {
        Ok(#(decoder, new)) ->
          push_chunks(decoder, rest, sizes, all, [new, ..items])
        Error(error) -> Error(error)
      }
    }
  }
}

// Properties ------------------------------------------------------------------

pub fn decode_matches_the_reference_test() -> Nil {
  metamon.forall(wire_gen(), fn(wire) {
    assert decode(wire) == Ok(reference(wire))
  })
}

pub fn chunking_does_not_change_the_items_test() -> Nil {
  metamon.forall(generator.tuple2(wire_gen(), sizes_gen()), fn(input) {
    let #(wire, sizes) = input
    assert decode_in_chunks(wire, sizes) == decode(wire)
  })
}

pub fn one_byte_chunks_match_the_reference_test() -> Nil {
  metamon.forall(wire_gen(), fn(wire) {
    assert decode_in_chunks(wire, [1]) == Ok(reference(wire))
  })
}

pub fn line_ending_does_not_change_the_items_test() -> Nil {
  // Writing every line ending of a stream as LF, CRLF or CR gives the
  // same items. The pieces hold no CR or LF, so only the line ending
  // differs.
  let line =
    generator.list_of(
      generator.filter(piece_gen(), fn(piece) {
        !list.contains(
          [<<"\n":utf8>>, <<"\r":utf8>>, <<"\r\n":utf8>>, <<"\n\n":utf8>>],
          piece,
        )
      }),
      generator.range(from: 0, to: 6),
    )
    |> generator.map(bit_array.concat)
  metamon.forall(
    generator.list_of(line, generator.range(from: 0, to: 8)),
    fn(lines) {
      let wire = fn(ending) {
        lines |> list.map(fn(l) { <<l:bits, ending:bits>> }) |> bit_array.concat
      }
      let lf = decode(wire(<<"\n":utf8>>))
      assert decode(wire(<<"\r\n":utf8>>)) == lf
      assert decode(wire(<<"\r":utf8>>)) == lf
    },
  )
}

pub fn reference_follows_the_examples_in_the_standard_test() -> Nil {
  // The examples in the standard, run through the reference and the
  // decoder, so that a mistake in the reference does not hide one in the
  // decoder.
  let examples = [
    #(<<"data: YHOO\ndata: +2\ndata: 10\n\n":utf8>>, [
      EventItem(ssevents.new("YHOO\n+2\n10")),
    ]),
    #(
      <<
        ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n":utf8,
      >>,
      [
        support.comment("test stream"),
        EventItem(support.id(ssevents.new("first event"), "1")),
        EventItem(support.id(ssevents.new("second event"), "")),
        EventItem(ssevents.new(" third event")),
      ],
    ),
    #(<<"data\n\ndata\ndata\n\ndata:":utf8>>, [
      EventItem(ssevents.new("")),
      EventItem(ssevents.new("\n")),
    ]),
    #(<<"data:test\n\ndata: test\n\n":utf8>>, [
      EventItem(ssevents.new("test")),
      EventItem(ssevents.new("test")),
    ]),
  ]
  list.each(examples, fn(example) {
    let #(wire, items) = example
    assert reference(wire) == items
    assert decode(wire) == Ok(items)
  })
}
