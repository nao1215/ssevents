# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **encoder**: `normalise_newlines` now rewrites every CRLF / lone CR
  to LF in a single byte-level pass. The previous two-pass
  `string.replace` shape could leak a lone CR into the wire on the
  BEAM for inputs whose `\r\n` neighbours another `\r` — e.g.
  `" 0Az~\n\r\r\n"` produced wire bytes containing a literal `CR`
  inside a `data:` line, breaking `decode(encode(event))`
  round-tripping. The single-pass walker is also robust against
  whatever the underlying `string.replace` does on each target. (#58)
- **decoder**: `trim_optional_leading_space` (used for the optional
  U+0020 SPACE after the field colon) now drops a single UTF-8
  code point rather than calling `string.drop_start(.., up_to: 1)`.
  The latter operates on grapheme clusters, so when the byte after
  the space was a combining mark such as U+1B00 BALINESE SIGN ULU
  RICEM or U+0301 COMBINING ACUTE ACCENT, the whole `space + mark`
  cluster was deleted and the mark was silently lost on decode.
  The fix uses `string.to_utf_codepoints` so it is grapheme-cluster-
  agnostic and also BOM-safe on JavaScript (where round-tripping
  through `bit_array.to_string` would have stripped a leading
  U+FEFF). The fix applies to `event:`, `id:`, and comment lines
  (which share the helper). (#59)
- **event**: `event.retry/2` and `event.from_parts(retry: Some(_))`
  now silently coerce out-of-range retry values to `None` at
  construction. Previously a negative `Some(n)` survived into the
  wire output but was dropped by §9.2.6's ASCII-digits rule on
  decode, and a value above `limit.default_max_retry_value`
  (24 hours in milliseconds) hard-failed the default decoder with
  `InvalidRetry`. `decode(encode(event))` now round-trips for any
  caller-built `Event` — matching the silent-sanitisation posture
  already used for CR / LF / NUL inside `event:` and `id:` (#39). (#60)

## [0.6.0] - 2026-05-04

### Documentation

- **examples**: Add a Wisp wiring snippet under
  "Wiring SSE bytes into a web framework" in `examples/README.md`.
  Shows the four required SSE response headers plus
  `ssevents.encode_items_bytes` flowing into a `wisp.bit_array_response`,
  with a closing paragraph pointing at per-event encoding for
  long-lived chunked streams and noting that the same shape applies
  to Mist. The snippet stays as documentation rather than a runnable
  example so the package keeps zero framework dependencies. (#55)

## [0.5.0] - 2026-04-30

### Added

- **tests**: cross-target parity and chunk-boundary tests under
  `test/ssevents/parity_test.gleam`, covering encode/decode round-trip
  parity, parameterised chunk-size parity, every-split-position parity,
  line-ending (Lf/Crlf) parity, and encode/concat parity over a curated
  15-item corpus that exercises empty data, multi-line data, named
  events, retry boundaries, multi-byte UTF-8, and a 300-byte payload.
  The new file is target-agnostic Gleam, so it runs on both
  `--target erlang` and `--target javascript` via the existing test
  recipes. Each test function is tagged with the documented invariant
  (I1–I8) it asserts so future contributors know what must stay
  stable. (#47)
- **examples**: three runnable Gleam projects under `examples/`
  (`quick_start`, `streaming_consume`, `server_emit`), each depending
  on `ssevents` via a path dependency. They show the encode/decode
  round-trip path, incremental decoding with reconnect-metadata
  tracking, and producing the `BitArray` chunk sequence an HTTP server
  would write to a `text/event-stream` response. (#46)
- **docs**: `examples/README.md` documents the required HTTP response
  headers (`Content-Type`, `Cache-Control: no-cache, no-transform`,
  `Connection: keep-alive`, `X-Accel-Buffering: no`), browser-side
  `EventSource` usage, framework wiring (Mist, Wisp), `gleam/yielder`
  interop, proxy buffering / compression / caching caveats, and
  `Last-Event-ID` resume semantics. The top-level README now points
  to it. (#46)
- **ci**: a new `examples` job in `.github/workflows/ci.yml` runs
  `just examples` on every push, building and running each example
  with `--warnings-as-errors` so they stay compile-checked across
  changes to the core API. (#46)

## [0.4.0] - 2026-04-30

### Added

- **limit**: `limit.new_checked(...)` returns
  `Result(Limits, LimitConfigError)` instead of panicking on a
  non-positive value, and the new `LimitConfigError.NonPositiveLimit(field:, given:)`
  variant lets callers route configuration failures through their
  normal result chain. Use this when limit values come from
  application config, environment variables, or framework settings;
  the panicking `limit.new` remains the right tool for hard-coded
  programmer-trusted constants. (#49)
- **validate**: `validate.max_data_bytes_checked(...)` returns
  `Result(Result(event.Event, SseError), LimitConfigError)`, splitting
  argument-validation failures (outer `Error`, configuration-shaped)
  from event-validation failures (inner `Result`, the existing
  `EventTooLarge` path). Use this when the size cap is sourced from
  dynamic input. (#49)

## [0.3.0] - 2026-04-30

### Fixed

- **Construction: `event` and `id` values are now sanitised on the way
  in** — CR (U+000D), LF (U+000A), and NUL (U+0000) are silently
  stripped from the value passed to `from_parts`, `event/2`, and
  `id/2`. The encoder previously emitted those bytes verbatim,
  producing wire that the decoder either silently corrupted (LF
  splits the field across two lines, the post-LF tail is parsed as
  an unrelated unknown field) or rejected (NUL in id triggered the
  field-validation path before this release introduced silent-ignore).
  After this fix `decode(encode(x))` round-trips for any caller-built
  `Event`, matching the posture `multipartkit/form` already takes for
  header values. (#39)
- **Decoder: lone CR (U+000D) is now accepted as a line separator** per
  WHATWG SSE §9.2.5, alongside CRLF and lone LF. A stream like
  `data: a\rdata: b\r\r` now decodes the same as the LF-terminated
  shape (one event with data `"a\nb"`). The incremental decoder still
  waits when a buffer ends with CR (could become CRLF on the next
  push), but `finish` on a buffer ending in CR is no longer an
  `Error(UnexpectedEnd)` — the trailing CR is treated as a lone-CR
  terminator since no more bytes are coming. (#38)
- **Decoder: `retry` field that isn't all ASCII digits is now silently
  ignored** per WHATWG SSE §9.2.6, instead of failing the whole decode
  with `Error(InvalidRetry(value))`. Affects `12.5` (decimal),
  `-100` (negative — `-` isn't an ASCII digit), the empty string, and
  any value containing letters or punctuation. The surrounding event
  still dispatches from its other fields. The custom `max_retry_value`
  safety bound (a per-decoder DoS limit, not a spec rule) continues
  to be a hard `Error(InvalidRetry(value))`. **Behavioural change**:
  `decode("retry: nope\n\n")` previously returned
  `Error(InvalidRetry("nope"))`; it now returns `Ok([])` (event has
  no `data:` so nothing to dispatch). (#37)
- **Decoder: `id` field with U+0000 NUL is now silently ignored** per
  WHATWG SSE §9.2.6, instead of failing the entire decode with
  `Error(InvalidField("id"))`. The directive in the spec is to drop
  the *field*, not to fail the *event* — a producer cannot signal
  "ignore the entire event you were assembling" via a malformed id.
  An event with a NUL-tainted id and a valid `data:` line now
  dispatches with the data intact and `id_of(_) == None`. (#36)
- **Decoder: leading UTF-8 BOM (U+FEFF) is now stripped** before
  parsing, per WHATWG SSE §9.2.5. Previously a stream that began
  with the three-byte BOM (`EF BB BF`) — common from UTF-8 emitters
  like `iconv -t UTF-8` and hand-edited fixtures — failed to parse
  the first event. The check runs once per `DecodeState` (tracked
  via a new `bom_handled` flag) and correctly handles the
  incremental decoder when the BOM is split across `push` calls. (#35)

## [0.2.0] - 2026-04-29

### Added

- `ssevents.error_to_string` re-exports `error.to_string` on the facade,
  so user code that needs to format an `SseError` no longer has to
  reach into the `ssevents/error` submodule.
- Initial Gleam project scaffold with package metadata, CI workflows,
  release automation, `just` tasks, mise toolchain pinning, and
  baseline source/test layout.
- Core SSE implementation:
  `ssevents/event`, `encoder`, `decoder`, `stream`, `reconnect`,
  `validate`, `heartbeat`, `error`, and `limit`.
- Full-body and incremental decoding with LF / CRLF support, unknown
  field ignore semantics, EOF final-event dispatch, and explicit limit
  enforcement.
- Deterministic encoding for events, comments, and item sequences on
  both Erlang and JavaScript targets.
- Reconnect helpers for `Last-Event-ID` and retry metadata.
- Cross-target test coverage for roundtrip behavior, partial chunks,
  UTF-8 chunk boundaries, retry parsing, comments, and limit
  violations.

### Changed

- `error.to_string` for `InvalidRetry` now states the constraint
  ("must be a non-negative integer") so the message is actionable
  without consulting the SSE spec.

- `reconnect.update` now uses `option.or` for the
  "prefer-new-fall-back-to-old" merge of `last_event_id` / `retry`,
  replacing the explicit `case` ladders with a single idiomatic
  expression.

- Decoder field splitting now propagates `Error(InvalidUtf8)` instead of
  silently substituting an empty string when a `BitArray` → `String`
  decode fails. The previous `unsafe_text` helper has been removed; the
  in-practice path through `decode_line` continues to reject invalid
  UTF-8 upstream, so observable behavior is unchanged for valid inputs.

- `validate.validate_event_name` and `validate.validate_id` now share a
  single `validate_no_forbidden_bytes` helper. No behavior change;
  removes the duplicated body so adding a new validated field is a
  one-liner.

- `stream.pull_decoded` is split into focused private helpers
  (`step_decoded`, `advance_decoder`, `handle_push`, `handle_finish`,
  `terminal_error`). Concerns (pending emission, chunk pulling,
  decoder-result translation, error termination) are now layered
  instead of interleaved; the original six levels of nested `case`
  collapse to two.

- **Breaking:** the facade-level `Event` accessor is renamed
  `ssevents.event_name` → `ssevents.name_of` so the four event
  accessors share the `*_of` suffix already used by `data_of`,
  `id_of`, and `retry_of`. Callers that read the event name through
  the facade need to update the call site.

- `decoder.apply_field_parts` no longer hand-rolls four near-identical
  branches for `data` / `event` / `id` / `retry`. The three
  validated-then-set fields share a new `apply_validated_field` helper
  that takes the validation `Result` plus a setter closure; `data`
  keeps its dedicated `apply_data_field` because it has its own
  `TooManyDataLines` limit check. Adding a new validated field now
  costs one entry in the `case`, not a copy-pasted block.

- The monolithic `test/ssevents_test.gleam` is split into
  module-aligned files under `test/ssevents/`: `event_test`,
  `encoder_test`, `decoder_test`, `stream_test`, `reconnect_test`,
  `validate_test`, and `error_test`. The top-level
  `test/ssevents_test.gleam` keeps the gleeunit `main` entry, the
  package-name smoke check, the cross-cutting encode/decode roundtrip,
  and the facade-vs-submodule `error_to_string` parity check. Total
  test count is preserved (40 tests, both Erlang and JavaScript
  targets).

### Performance

- `decoder.ends_with_cr` is now O(1): it slices the last byte of the
  buffered chunk instead of reversing the whole buffer just to look at
  the final byte. Removes a per-`push` cost that scaled with the
  configured `max_event_bytes`.

### Documentation

- Document the release process in the README so the `gleam.toml`
  version, the `[Unreleased]` → `[X.Y.Z] - YYYY-MM-DD` rename, and the
  `vX.Y.Z` tag that drives `release.yml` stay in sync.

- The `ssevents` facade module is now declared the canonical public
  surface in its top-of-file doc comment; submodules are an
  implementation detail and may be reorganized between releases. The
  README's "Decode a full body" example switches from
  `ssevents/error.to_string` to the new facade-level
  `ssevents.error_to_string` to match.
