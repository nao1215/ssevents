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
