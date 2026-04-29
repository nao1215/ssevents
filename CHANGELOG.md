# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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

### Performance

- `decoder.ends_with_cr` is now O(1): it slices the last byte of the
  buffered chunk instead of reversing the whole buffer just to look at
  the final byte. Removes a per-`push` cost that scaled with the
  configured `max_event_bytes`.

### Documentation

- Document the release process in the README so the `gleam.toml`
  version, the `[Unreleased]` → `[X.Y.Z] - YYYY-MM-DD` rename, and the
  `vX.Y.Z` tag that drives `release.yml` stay in sync.
