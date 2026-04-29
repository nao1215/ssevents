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

### Choosing an encode function

- `encode` / `encode_bytes` operate on `Event`.
- `encode_item` / `encode_item_bytes` operate on `Item`, so they can
  encode either an event or a comment.
- `encode_items` / `encode_items_bytes` operate on a whole `List(Item)`.
- `*_bytes` returns `BitArray` for HTTP response bodies and socket
  writes; the non-suffixed variants return `String` for logging,
  debugging, and tests.

### Encode one event

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

### Encode a whole SSE response body

```gleam
import ssevents

pub fn encode_response_body() -> String {
  [
    ssevents.comment("stream opened"),
    ssevents.named("job.started", "job-123")
    |> ssevents.id("cursor-1")
    |> ssevents.event_item,
    ssevents.heartbeat(),
  ]
  |> ssevents.encode_items
}
```

### Decode a full body

```gleam
import ssevents
import ssevents/error as sse_error

pub fn decode_example(body: BitArray) {
  case ssevents.decode_bytes(body) {
    Ok(items) -> items
    Error(error) -> [ssevents.comment(sse_error.to_string(error))]
  }
}
```

### Incremental decode

```gleam
import ssevents

pub fn incremental_decode() {
  let state = ssevents.new_decoder()
  let assert Ok(#(state, items1)) =
    ssevents.push(state, <<"data: hel":utf8>>)
  let assert [] = items1

  let assert Ok(#(state, items2)) =
    ssevents.push(state, <<"lo\n\n":utf8>>)
  let assert [item] = items2

  let assert Ok(items3) = ssevents.finish(state)
  #(item, items3)
}
```

### Stream adapter

```gleam
import ssevents

pub fn streaming_example() {
  let chunks =
    ssevents.iterator_from_list([
      <<"data: first\n\n":utf8>>,
      <<"data: second\n\n":utf8>>,
    ])

  chunks
  |> ssevents.decode_stream
  |> ssevents.iterator_to_list
}
```

### Decoding untrusted input

If the peer is untrusted, set explicit decoder limits instead of
relying on the package defaults. The limit knobs are:

- `max_line_bytes`
- `max_event_bytes`
- `max_data_lines`
- `max_retry_value`

```gleam
import ssevents

pub fn safe_decode(body: BitArray) {
  let limits =
    ssevents.new_limits(
      max_line_bytes: 4096,
      max_event_bytes: 65536,
      max_data_lines: 256,
      max_retry_value: 60000,
    )

  ssevents.decode_bytes_with_limits(body, limits: limits)
}
```

The built-in defaults are suitable for development and trusted inputs.
Production clients and servers should choose limits that match their
own traffic shape and threat model.

See [SECURITY.md](SECURITY.md) for the project security policy.

### Track reconnect metadata

```gleam
import ssevents

pub fn reconnect_example(item: ssevents.Item) {
  let state =
    ssevents.new_reconnect_state()
    |> ssevents.update_reconnect(item)

  #(
    ssevents.last_event_id(state),
    ssevents.retry_interval(state),
    ssevents.last_event_id_header(state),
  )
}
```

## Development

```sh
mise install
just ci
```

## License

MIT. See [LICENSE](LICENSE).
