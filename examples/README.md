# ssevents examples

Each subdirectory is a self-contained Gleam project that depends on
`ssevents` via a path dependency. Run any of them with:

```sh
cd examples/<name>
gleam run
```

| Example | What it shows |
|---|---|
| `quick_start` | Build a list of SSE items, encode them to a wire-ready byte string, and decode back. The shortest "first success" path. |
| `streaming_consume` | Drive the incremental decoder with chunks split at awkward boundaries (BOM, mid-event, mid-line) and track `Last-Event-ID` / `retry` so reconnects can resume from the right cursor. |
| `server_emit` | Produce the sequence of `BitArray` chunks an HTTP server would write to a `text/event-stream` response, plus the response header set every SSE endpoint should send. |

The repository `justfile` has `example-*` recipes that build and run
each example with `--warnings-as-errors`, and a single `examples`
recipe that runs them all. CI runs `just examples` on every push.

## HTTP response headers for an SSE endpoint

`ssevents` is runtime-agnostic, but the wire format only works if the
HTTP server cooperates. Send these headers from whichever framework
you use:

| Header | Value | Why |
|---|---|---|
| `Content-Type` | `text/event-stream` | Mandated by the SSE spec. The constant is exposed as `ssevents.content_type()` so framework adapters can read it without hardcoding. |
| `Cache-Control` | `no-cache, no-transform` | Prevents intermediaries from caching or rewriting the stream. `no-transform` matters because some proxies will gzip/transcode `text/*` by default. |
| `Connection` | `keep-alive` | The SSE spec assumes a single long-lived connection. |
| `X-Accel-Buffering` | `no` | nginx and several ingress controllers buffer responses by default; this header opts the response out of buffering. |

If you serve the endpoint behind a reverse proxy (nginx, Cloudflare,
an API gateway), confirm that **proxy-level response buffering** is
disabled for that route. A buffered SSE stream will appear to work
locally but stall in production.

## Wiring SSE bytes into a web framework

`ssevents` does not depend on Wisp, Mist, or any specific HTTP
framework — it just produces the right bytes. The snippet below is
the smallest end-to-end shape for a Wisp handler returning a finite
SSE response. It is shown here as documentation rather than as a
runnable example so the package's dev-dependency surface stays small.

```gleam
import gleam/bytes_tree
import ssevents
import wisp.{type Request, type Response}

/// `GET /events` — return a finite, pre-encoded SSE response. For an
/// open-ended live stream, swap `wisp.bit_array_response` for the
/// chunked / streaming response shape your framework offers and feed
/// it `ssevents.encode_item_bytes(item)` per emit.
pub fn handle_events(_req: Request) -> Response {
  let body =
    [
      ssevents.comment("stream opened"),
      ssevents.named("job.started", "build #42")
        |> ssevents.id("cursor-1")
        |> ssevents.event_item,
      ssevents.named("job.progress", "step 1/3")
        |> ssevents.id("cursor-2")
        |> ssevents.event_item,
      ssevents.named("job.finished", "ok")
        |> ssevents.id("cursor-3")
        |> ssevents.event_item,
    ]
    |> ssevents.encode_items_bytes

  wisp.bit_array_response(body, 200)
  |> wisp.set_header("content-type", ssevents.content_type())
  |> wisp.set_header("cache-control", "no-cache, no-transform")
  |> wisp.set_header("connection", "keep-alive")
  |> wisp.set_header("x-accel-buffering", "no")
}
```

The same shape works for Mist: build the body with the encoders,
attach the four headers above, and hand the bytes to whichever
response constructor the framework exposes (`mist.Bytes` for a
buffered response, the chunked-body builder for a long-lived stream).
For a long-lived stream, prefer per-event encoding —
`ssevents.encode_item_bytes(item)` — so each chunk you write is a
complete event terminated by the SSE blank line; the browser-side
`EventSource` will then dispatch as soon as each chunk lands rather
than waiting for the full response.

## Browser client

The browser side is plain JavaScript — `ssevents` does not produce a
JS client component; the browser already has `EventSource`:

```javascript
const source = new EventSource("/events", { withCredentials: false });

source.addEventListener("job.started", (e) => {
  // e.lastEventId carries the `id:` field if the server sent one
  console.log("started", e.lastEventId, e.data);
});

source.addEventListener("job.progress", (e) => {
  console.log("progress", e.data);
});

source.onerror = () => {
  // EventSource auto-reconnects honoring the server's `retry:` hint.
  // It also re-sends `Last-Event-ID` automatically.
  console.warn("disconnected; will retry");
};
```

`EventSource` automatically:

- reconnects on transport errors,
- honours the most recent `retry:` value the server sent,
- includes the most recent `id:` in a `Last-Event-ID` request header on
  every reconnect.

Server-side, decode that header to resume from the right cursor:

```gleam
import ssevents

pub fn resume_cursor(last_event_id_header: option.Option(String)) {
  case last_event_id_header {
    option.Some(cursor) -> resume_from(cursor)
    option.None -> start_from_head()
  }
}
```

## Server frameworks

`ssevents` does not lock you to a particular HTTP server. The pattern
is the same for every framework: produce `BitArray` chunks via
`encode_*_bytes`, then write them to the framework's response stream.

### Mist (low-level HTTP server on the BEAM)

```gleam
import gleam/erlang/process
import gleam/http/response
import mist
import ssevents

pub fn handler(_request) {
  let assert Ok(subject) = process.new_subject()

  // Spawn whatever produces events for this client and sends them
  // as `BitArray` messages to `subject`.
  spawn_event_source(subject)

  let body =
    mist.Chunked(stream_from_subject(subject))

  response.new(200)
  |> response.set_header("content-type", ssevents.content_type())
  |> response.set_header("cache-control", "no-cache, no-transform")
  |> response.set_header("x-accel-buffering", "no")
  |> response.set_body(body)
}
```

The `BitArray` chunks come straight out of `ssevents.encode_item_bytes`
or `ssevents.encode_items_bytes`. See the `server_emit` example for a
self-contained version of the producer.

### Wisp (request/response framework on top of Mist)

Wisp's `wisp.response_with_body` accepts a streaming body. The shape
is the same: write `ssevents.encode_item_bytes(item)` chunks as they
become available, and set the four headers above.

### JavaScript target

On the JavaScript target, the consumer-side `ReadableStream` reader
gives you `Uint8Array` chunks. Wrap each chunk into a `BitArray` and
feed it to `ssevents.push`:

```gleam
import ssevents

pub fn consume_chunk(state: ssevents.DecodeState, chunk: BitArray) {
  case ssevents.push(state, chunk) {
    Ok(#(next_state, items)) -> handle_items(next_state, items)
    Error(error) -> abort(error)
  }
}
```

## Interop with `gleam/yielder` and chunk producers

If your event producer is already a `gleam/yielder.Yielder` of items
(or of bytes), `ssevents/stream` exposes adapters:

- `ssevents.encode_stream(items: Iterator(Item)) -> Iterator(BitArray)`
  encodes lazily — convenient when you do not want to materialise the
  whole list before writing.
- `ssevents.decode_stream(chunks: Iterator(BitArray)) -> Iterator(Result(Item, SseError))`
  decodes lazily, surfacing one decoded item per `next` step.

The adapters are thin wrappers over `push` / `finish` and incur no
extra buffering beyond what the underlying iterator does. They are the
right fit when you want a single value to flow through the system as a
stream rather than as a callback.

If you only need to feed bytes one chunk at a time (e.g. from a
non-iterator API), use `new_decoder` + `push` + `finish` directly —
that is the path the `streaming_consume` example takes.

## Buffering caveats

- **Proxy buffering**. Always set `X-Accel-Buffering: no` and
  double-check the proxy config; a buffered stream will appear to work
  in dev and stall in production.
- **Heartbeats**. Some clients and proxies close idle connections
  after 30–60 seconds. Send `ssevents.heartbeat()` (a `: heartbeat`
  comment) every ~15s to keep the path warm without polluting the
  event stream.
- **Compression**. Disable response compression for the SSE route.
  gzip's framing layer will buffer until the encoder flushes, which
  defeats the purpose of streaming. `Cache-Control: no-transform`
  signals this to compliant intermediaries.
- **HTTP/2**. SSE works fine over HTTP/2 and HTTP/3. There is no need
  to force HTTP/1.1 unless you have an old client constraint.

## Caching caveats

- Response is **not** cacheable. `Cache-Control: no-cache, no-transform`
  prevents shared and private caches from storing and replaying it.
- If you also serve a non-SSE route at the same path with content
  negotiation, send `Vary: Accept` so caches do not collapse the two.
- CDN edge nodes typically refuse to cache `text/event-stream`
  responses; verify with your provider before depending on the
  behaviour.

## Last-Event-ID and resume semantics

The browser sends `Last-Event-ID: <value>` automatically on reconnect.
What that value means is up to your server — the spec does not impose
ordering or persistence. Two common approaches:

- **Cursor**. The id is an opaque cursor into your event log; the
  server resumes from the next event after that cursor. Easiest to
  reason about; requires durable storage of past events.
- **Sequence**. The id is a monotonically increasing sequence number;
  the server replays events with `id > last_event_id` from a recent
  buffer. Cheaper to implement; only safe up to the buffer's history
  window.

Either way, the server-side surface is the same: decode the
`Last-Event-ID` header on connect, then drive `ssevents.update_reconnect`
on the items you produce so a downstream `retry` value or `id` change
is reflected in `last_event_id_header`. See the `streaming_consume`
example.
