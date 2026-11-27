# Testing

`just ci` runs everything below except the nightly job and mutation testing (`just mutation`). Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x, and `just examples` builds and runs every program under `examples/`.

## Examples and unit tests

`test/ssevents/*_test.gleam` checks the decoder, the encoder, event construction, limits and reconnect state against the WHATWG event stream rules with fixed inputs. Each fixed bug keeps its reproduction in a `regression_*_test.gleam` file or next to the related tests. `test/readme_test.gleam` runs the README example and the examples in the doc comments.

## The WHATWG rules

`test/ssevents/spec_test.gleam` has one test per rule of "Interpreting an event stream" in the WHATWG HTML standard that the decoder once got wrong, and `test/ssevents/spec_reference_test.gleam` compares `decode` with a reference decoder written from that section on random bytes: field names in every case, colons, spaces, NUL, the three line endings, a byte order mark and bytes that are not UTF-8. The reference decodes the whole stream to code points first with the byte-at-a-time decoder of the WHATWG Encoding standard, while `ssevents` splits lines on bytes and decodes each line, so the two only agree if both follow the standard. The same file checks that cutting the input into chunks of any size, or one byte at a time, and writing every line ending as LF, CRLF or CR give the same items. It runs the examples of the standard through both decoders.

| Rule of the standard | What `ssevents` does | Tests |
|---|---|---|
| The stream is read with UTF-8 decode, which skips one leading byte order mark and reads invalid bytes as U+FFFD | The same; a mark split across chunks is not counted as a line | `spec_test`, `decoder_test`, `parity_test` |
| A line ends with CRLF, LF or CR, and a last line without one is not a line | The same | `decoder_test`, `spec_test`, `spec_reference_test` |
| A blank line dispatches the event | The same | `decoder_test` |
| A line starting with a colon is ignored | It is returned as a `CommentItem`, with one leading space removed | `decoder_test`, `parity_test` |
| A field is split at the first colon, and one leading space of the value is removed; a line without a colon is a field with an empty value | The same | `decoder_test`, `spec_reference_test` |
| Field names are compared exactly, and unknown fields are ignored | The same | `decoder_test`, `spec_reference_test` |
| `event` sets the event type, and an empty one is `message` | The same; the name keeps NUL | `decoder_test`, `spec_test` |
| `data` appends its value and an LF, and the last LF is removed at dispatch | The lines are joined with LF; the data keeps NUL | `decoder_test`, `spec_reference_test` |
| `id` with NUL is ignored, any other `id` sets the last event id, even for a block without `data` | The same; a block without `data` gives a `ReconnectItem` | `decoder_test`, `spec_test` |
| `retry` that is all ASCII digits sets the reconnection time when it is read, any other is ignored | The same, and a value above `max_retry_value` is ignored; the value of an event cut off at the end comes from `finish` as a `ReconnectItem` | `decoder_test`, `boundary_test`, `spec_test` |
| A block without `data` dispatches nothing | It gives a `ReconnectItem` if it has an `id` or a `retry`, and nothing otherwise | `spec_test` |
| An event the stream ends before its blank line is discarded | The same | `spec_test` |

## Generated properties

`test/ssevents_metamon_test.gleam` uses metamon: data, names, ids and retry values survive encode then decode, only line terminators are rewritten, every encoded event ends with a blank line, and comments round-trip.

## Chunk parity

`test/ssevents/parity_test.gleam` feeds a corpus of encoded streams to the incremental decoder in chunks of many sizes and at every split position, with LF, CRLF and a leading BOM, and requires the same items as the one-shot decoder. `test/ssevents/encode_determinism_test.gleam` checks that the encoded text does not depend on the order of the builder calls.

## Differential testing

`test/ssevents/limits_differential_test.gleam` compares the one-shot decoder (`decode`) with the incremental one (`push` / `finish`) on random wire text the encoder never writes: LF, CRLF and lone CR mixed, unknown fields, fields without a colon, NUL in ids, bad and oversized retry values and comments, cut into random chunk sizes. Both must return the same items or the same error with the default limits and with each limit set one below, at and one above what the input needs. This test found that a CR at the end of a chunk was counted towards `max_line_bytes`.

## Boundary values

`test/ssevents/boundary_test.gleam` checks the limits both decoders share exactly at their thresholds: a line of exactly `max_line_bytes`, an event of exactly `max_event_bytes`, exactly `max_data_lines`, 0 as every limit, a retry of 0, an empty retry value and CR / LF / NUL in names and ids.

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.Config(..metamon.default_config(), seed: Some(seed))` and kept as a regression test.

## Mutation testing

`gleam run -m metamon/mutation` changes one operator, `!` or boolean literal in `src/ssevents.gleam` at a time and runs `gleam test --target erlang` on each change. `.github/workflows/mutation.yml` mutates the module on every pull request that changes it and fails on a survivor that `doc/mutation/baseline.json` does not list; the weekly run does the same.

The first run with it (2026-11-27) scored 93.4%, with more mutants than the hand-run tool of 2026-11-23 because it also changes the boolean fields of records. Tests were added for a byte order mark at the start of a later chunk, after a first chunk with or without one, and the score rose to 96.7%. The two survivors left change nothing: the decoder starts with `skip_lf: False`, and starting with `True` only skips an LF at the very start of the stream, which is a blank line with no event to dispatch; and `skip_lf_after_cr` clearing the flag when the next chunk starts with another byte, since the next line end in that chunk sets the flag again and, until then, the buffer is not empty.

<!-- mutation:start -->
| Module | Killed | Lived | Timed out | Score |
|---|---:|---:|---:|---:|
| `ssevents` | 59 | 2 | 0 | 96.7% |
| all | 59 | 2 | 0 | 96.7% |
<!-- mutation:end -->
