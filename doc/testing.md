# Testing

`just ci` runs everything below except the nightly job and mutation testing. Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x, and `just examples` builds and runs every program under `examples/`.

## Examples and unit tests

`test/ssevents/*_test.gleam` checks the decoder, the encoder, event construction, validation, limits and reconnect state against the WHATWG event stream rules with fixed inputs. Each fixed bug keeps its reproduction in a `regression_*_test.gleam` file or next to the related tests.

## Generated properties

`test/ssevents_metamon_test.gleam` uses metamon: data, names, ids and retry values survive encode then decode, only line terminators are rewritten, every encoded event ends with a blank line, and comments round-trip.

## Chunk parity

`test/ssevents/parity_test.gleam` feeds a corpus of encoded streams to the incremental decoder in chunks of many sizes and at every split position, with LF, CRLF and a leading BOM, and requires the same items as the one-shot decoder. `test/ssevents/encode_determinism_test.gleam` checks that the encoders agree with each other.

## Differential testing

`test/ssevents/limits_differential_test.gleam` compares the one-shot decoder (`decode_bytes_with_limits`) with the incremental one (`push` / `finish`) on random wire text the encoder never writes: LF, CRLF and lone CR mixed, unknown fields, fields without a colon, NUL in ids, bad and oversized retry values and comments, cut into random chunk sizes. Both must return the same items or the same error with the default limits and with each limit set one below, at and one above what the input needs. This test found that a CR at the end of a chunk was counted towards `max_line_bytes`.

## Boundary values

`test/ssevents/boundary_test.gleam` checks the limit and validation checks both decoders share exactly at their thresholds: an event of exactly `max_event_bytes`, `max_data_bytes` at and below the data size, 0 and 1 as limit values, a retry of 0, an empty retry value and CR / LF / NUL in names and ids.

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.with_seed` and kept as a regression test.

## Mutation testing

There is no mutation testing tool for Gleam, so `gleam_mutate.py` (from the mutation-testing lab in nao1215/debimate, with integer comparison and arithmetic operators added) is run by hand on a copy of the project. It rewrites one operator or boolean result at a time (`==`/`!=`, `<`/`<=`, `>`/`>=`, `+`/`-`, `&&`/`||`, `-> True`/`-> False`, a dropped `!`) and runs `gleam test` on the Erlang target. The score is killed / (killed + lived).

| Date | Files | Killed | Lived | Score |
|---|---|---:|---:|---:|
| 2026-11-19 | every module under `src/`, with the differential test | 38 | 13 | 74.5% |
| 2026-11-19 | the same, plus `test/ssevents/boundary_test.gleam` | 45 | 6 | 88.2% |

The differential test cannot see a threshold that moves in both decoders at once, because they share the limit checks; `boundary_test.gleam` pins those checks at their thresholds. The remaining survivors:

- `encoder.chunk_data_line` (2): the 2000-code-point split of very long data lines, where `<=` and `<` only differ for a line of exactly 8000 bytes, which also stays one line after the split.
- `event.retry_clamp` (1): clamping 0 to 0.
- `decoder.is_ascii_digit_string` and `ends_with_cr` (2): an empty retry value fails `int.parse` and an empty buffer has no trailing CR either way.
- `validate.contains_forbidden_bytes` (1): the arm for a non-byte-aligned bit array, which a `String` never produces.
