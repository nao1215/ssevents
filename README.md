# ssevents

[![CI](https://github.com/nao1215/ssevents/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/ssevents/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/ssevents/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/ssevents/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/ssevents)](https://hex.pm/packages/ssevents)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ssevents/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ssevents)](https://hex.pm/packages/ssevents)
[![License](https://img.shields.io/github/license/nao1215/ssevents)](./LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/ssevents/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/ssevents)

`ssevents` encodes and decodes Server-Sent Events (SSE) in Gleam on
Erlang and JavaScript. It handles events and comments, full-body and
incremental decoding, reconnect metadata, validation, and chunk-stream
adapters in `ssevents/stream`. It does not depend on any web framework,
HTTP client, timer, filesystem or database, so client and server
libraries can both use it. The full API is on
[HexDocs](https://hexdocs.pm/ssevents/).

## Install

```sh
gleam add ssevents
```

## Usage

### Encode

```gleam
import ssevents

pub fn encode_response_body() -> String {
  [
    ssevents.comment("stream opened"),
    ssevents.named("job.started", "job-123")
    |> ssevents.id("cursor-1")
    |> ssevents.retry(5000)
    |> ssevents.event_item,
    ssevents.heartbeat(),
  ]
  |> ssevents.encode_items
}
```

The returned string:

```text
: stream opened
event: job.started
id: cursor-1
retry: 5000
data: job-123

: heartbeat
```

`encode` works on one `Event`, `encode_item` on one `Item` (event or
comment), and `encode_items` on a `List(Item)`. Each has a `*_bytes`
variant that returns a `BitArray` for response bodies and sockets.

`retry/2` panics on a negative value, because WHATWG SSE §9.2.6 only
allows a non-negative reconnection time. For untrusted input use
`ssevents.retry_clamp/2`, which raises negative values to `0` and turns
values above the 24 h cap (`limit.default_max_retry_value`) into `None`,
so no `retry:` line is written; `retry/2` and `from_parts/4` drop at the
same boundary, so the default decoder round-trips. For untrusted names,
ids or comment text, the `*_checked` variants (`event_checked`,
`id_checked`, `named_checked`, `comment_checked`) return an
`EventError` for CR / LF / NUL instead of stripping them.

### Decode a full body

```gleam
import ssevents

pub fn decode_example(body: BitArray) {
  case ssevents.decode_bytes(body) {
    Ok(items) -> items
    Error(error) -> [ssevents.comment(ssevents.error_to_string(error))]
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

The defaults suit development and trusted peers. For an untrusted peer,
set the four limits to match your traffic:

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

### Runnable examples

[`examples/`](./examples/) has standalone Gleam projects for emitting
from a server and consuming chunked input, plus notes on HTTP headers,
browser clients and reconnects. Run one with
`cd examples/<name> && gleam run`. `quick_start` prints:

```text
wrote 158 bytes of SSE
decoded 4 items:
- comment: stream opened
- event job.started, id=cursor-1, retry=5000ms: build #42
- event job.progress, id=cursor-2: step 1/3
running lints
- comment: heartbeat
```

## Development

```sh
mise install
just ci
```

## Release process

The version is in [`gleam.toml`](./gleam.toml) and the notes are in
[`CHANGELOG.md`](./CHANGELOG.md). Add entries under `[Unreleased]` while
developing. To release:

1. Bump `version = "X.Y.Z"` in `gleam.toml`.
2. In `CHANGELOG.md`, rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`
   and add a new empty `[Unreleased]` above it.
3. Merge the bump to `main`, then push a `vX.Y.Z` tag.

The tag runs
[`.github/workflows/release.yml`](./.github/workflows/release.yml),
which runs the checks, publishes to Hex, and creates a GitHub Release
whose body is the `[X.Y.Z]` section. If that section is missing or
misnamed, the release notes are empty.

## Testing

| Technique | Bug class caught here |
|---|---|
| Examples and unit tests | [Departures from the WHATWG event stream rules](doc/testing.md#examples-and-unit-tests) |
| Generated properties | [Encode / decode round trips that change data, names, ids or retry](doc/testing.md#generated-properties) |
| Chunk parity | [Incremental decoding that depends on where chunks split](doc/testing.md#chunk-parity) |
| Differential testing | [One-shot and incremental decoders disagreeing on odd input or at limits](doc/testing.md#differential-testing) |
| Boundary values | [Off-by-one limit and validation checks](doc/testing.md#boundary-values) |
| Nightly runs | [Rare inputs the normal run count misses](doc/testing.md#nightly-runs) |
| Mutation testing | [Assertions that miss a changed operator or branch](doc/testing.md#mutation-testing) |

## Verifying releases

Each GitHub Release attaches the Hex package tarball (`ssevents-<version>.tar`),
`checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and
build provenance (`ssevents-<version>.intoto.jsonl`). Download the assets, then:

```sh
gh attestation verify ssevents-<version>.tar --repo nao1215/ssevents

cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/nao1215/ssevents/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check checksums.txt
```

## License

MIT. See [LICENSE](LICENSE).
