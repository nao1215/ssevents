# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

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
