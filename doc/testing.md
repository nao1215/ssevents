# Testing

`just ci` runs everything below except the nightly job and mutation testing. Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x, and `just examples` builds and runs every program under `examples/`.

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

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.with_seed` and kept as a regression test.

## Mutation testing

There is no mutation testing tool for Gleam, so `gleam_mutate.py` (from the mutation-testing lab in nao1215/debimate, with integer comparison and arithmetic operators added) is run by hand on a copy of the project. It rewrites one operator or boolean result at a time (`==`/`!=`, `<`/`<=`, `>`/`>=`, `+`/`-`, `&&`/`||`, `-> True`/`-> False`, a dropped `!`) and runs `gleam test` on the Erlang target. The score is killed / (killed + lived).

| Date | File | Killed | Lived | Score |
|---|---|---:|---:|---:|
| 2026-11-23 | `src/ssevents.gleam` | 47 | 9 | 83.9% |
| 2026-11-23 | the same, with tests for the edges of each UTF-8 range and an 8000-byte `data` line | 52 | 4 | 92.9% |
| 2026-11-23 | the four survivors again, with those edges on a line that also holds an invalid byte | 56 | 0 | 100% |

The survivors were the range checks of the UTF-8 decoder, which only run on a line that holds an invalid byte, and the 8000-byte threshold of the `data` line split. Tables measured before the modules were merged into `src/ssevents.gleam` are dropped, because that code no longer exists. To measure again, copy the project, run `python3 gleam_mutate.py <copy> src/ssevents.gleam <result.json>` from the copy's parent, and after adding tests run it again with `--recheck <result.json>` to retry only the survivors.
