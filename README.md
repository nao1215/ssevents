# ssevents

[![CI](https://github.com/nao1215/ssevents/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/ssevents/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/ssevents/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/ssevents/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/ssevents/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/ssevents)](https://hex.pm/packages/ssevents)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ssevents/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ssevents)](https://hex.pm/packages/ssevents)
[![License](https://img.shields.io/github/license/nao1215/ssevents)](https://github.com/nao1215/ssevents/blob/main/LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/ssevents/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/ssevents)


Encode and decode Server-Sent Events, the `text/event-stream` format, in Gleam on Erlang and JavaScript.

A server builds events with `new` or `named` and writes them with `encode_items`. A client reads a body with `decode`, or chunk by chunk with `push`, within limits on line, event and `data` sizes. The decoder follows the WHATWG rules for interpreting an event stream, and gives the same items on both targets however the input is split. It needs only `gleam_stdlib`, so any HTTP server or client can use it.

```sh
gleam add ssevents@0
```

## Usage

This is [`examples/quick_start`](https://github.com/nao1215/ssevents/tree/main/examples/quick_start), which CI runs.

```gleam
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import ssevents.{CommentItem, EventItem, ReconnectItem}

pub fn main() {
  let assert Ok(opened) = ssevents.comment("stream opened")
  let assert Ok(started) =
    ssevents.named("job.started", "build #42")
    |> result.try(ssevents.id(_, "cursor-1"))
  let body =
    ssevents.encode_items([
      opened,
      ReconnectItem(id: None, retry: Some(5000)),
      EventItem(started),
      EventItem(ssevents.new("step 1/3\nrunning lints")),
    ])
  io.print(body)

  let assert Ok(items) = ssevents.decode(<<body:utf8>>, ssevents.default_limits)
  list.each(items, fn(item) {
    case item {
      EventItem(event) ->
        io.println("event data: " <> string.inspect(ssevents.data_of(event)))
      CommentItem(comment) ->
        io.println("comment: " <> ssevents.comment_text(comment))
      ReconnectItem(retry: Some(ms), ..) ->
        io.println("retry: " <> int.to_string(ms))
      ReconnectItem(..) -> Nil
    }
  })
}
```

```text
: stream opened
retry: 5000

event: job.started
id: cursor-1
data: build #42

data: step 1/3
data: running lints

comment: stream opened
retry: 5000
event data: "build #42"
event data: "step 1/3\nrunning lints"
```

A client that reads a response body in chunks gives each chunk to `push` and calls `finish` at the end. Use tighter limits than `default_limits` for a peer you do not trust:

```gleam
pub fn read_body(chunks: List(BitArray)) {
  let limits =
    ssevents.Limits(..ssevents.default_limits, max_event_bytes: 16_384)
  let start = #(ssevents.new_decoder(limits), [])
  use #(decoder, items) <- result.map(
    list.try_fold(chunks, start, fn(acc, chunk) {
      let #(decoder, items) = acc
      use #(decoder, new) <- result.map(ssevents.push(decoder, chunk))
      #(decoder, list.append(items, new))
    }),
  )
  list.append(items, ssevents.finish(decoder))
}
```

`update_reconnect` folds the items into a `ReconnectState` that holds the `id` to send back in `Last-Event-ID` and the last `retry`. A block with an `id` or a `retry` but no `data` comes out of the decoder as a `ReconnectItem`, so those reach the state too. [`examples/`](https://github.com/nao1215/ssevents/tree/main/examples) also shows the chunks a server writes, the response headers an SSE endpoint needs, and a browser client.

The API reference is on [HexDocs](https://hexdocs.pm/ssevents/).

## Notes

- `named`, `id` and `comment` return `Error(Nil)` for a value with CR or LF, and `id` also for one with NUL, so a value from a user cannot add lines or fields to the stream or reach the client changed. `new` turns CR and CRLF in `data` into LF, which is how a client reads them anyway.
- `encode` splits a `data` line longer than 8000 bytes into lines of at most 2000 code points, so that `decode` with `default_limits` can read it. The client joins them with LF, so the data it receives has an LF at each split. `event` and `id` lines are not split, so keep names and ids well under 8000 bytes.
- `retry` removes the field for a value below 0 or above 86_400_000 (24 hours), and `decode` ignores a larger value than `max_retry_value`.
- As in a browser, `decode` drops an event at the end of the input that has no closing blank line, and reads bytes that are not UTF-8 as U+FFFD.

How the package is tested is described in [doc/testing.md](https://github.com/nao1215/ssevents/blob/main/doc/testing.md).

## Verifying releases

Each GitHub Release attaches the tarball published to Hex (`ssevents-<version>.tar`), `checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and build provenance (`ssevents-<version>.intoto.jsonl`). The release workflow downloads the tarball from Hex after `gleam publish` and checks it against the checksum Hex records before signing it, so the tarball you get from Hex is the one that is signed and attested.

```sh
curl -fsSLO https://repo.hex.pm/tarballs/ssevents-<version>.tar
gh attestation verify ssevents-<version>.tar --repo nao1215/ssevents
```

To check the signature as well, download `checksums.txt` and `checksums.txt.sigstore.json` from the Release into the same directory. The workflow runs on the release tag, or on `main` when the assets of a published tag are attached again.

```sh
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/nao1215/ssevents/\.github/workflows/release\.yml@refs/(tags/v.+|heads/main)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check checksums.txt
```

## License

[MIT](https://github.com/nao1215/ssevents/blob/main/LICENSE)
