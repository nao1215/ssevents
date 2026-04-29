# ssevents

[![CI](https://github.com/nao1215/ssevents/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/ci.yml)
[![Hex](https://img.shields.io/hexpm/v/ssevents)](https://hex.pm/packages/ssevents)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ssevents)](https://hex.pm/packages/ssevents)
[![License](https://img.shields.io/github/license/nao1215/ssevents)](LICENSE)

`ssevents` is a Gleam library for working with Server-Sent Events
(SSE) on both the Erlang and JavaScript targets.

It provides a runtime-agnostic core for:

- constructing events and comments
- deterministic SSE encoding
- full-body and incremental decoding
- reconnect metadata tracking
- explicit validation helpers
- chunk-stream adapters via `ssevents/stream`

The core stays independent from web frameworks, HTTP clients, timers,
filesystems, and databases so it can be reused by both client and
server libraries.

## Install

```sh
gleam add ssevents
```

## Usage

```gleam
import ssevents

pub fn encode_example() -> BitArray {
  ssevents.new("job started")
  |> ssevents.event("job.update")
  |> ssevents.id("job-123:1")
  |> ssevents.retry(5000)
  |> ssevents.event_item
  |> ssevents.encode_item_bytes
}
```

```gleam
import ssevents

pub fn decode_example(body: BitArray) {
  ssevents.decode_bytes(body)
}
```

```gleam
import ssevents

pub fn streaming_example(chunks: ssevents.Iterator(BitArray)) {
  ssevents.decode_stream(chunks)
}
```

## Development

```sh
mise install
just ci
```

## Repository layout

- `src/` library modules
- `test/` gleeunit tests
- `.github/workflows/` CI and release automation
- `scripts/lib/mise_bootstrap.sh` shared toolchain bootstrap

## License

MIT. See [LICENSE](LICENSE).
