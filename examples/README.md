# ssevents examples

Each directory is a Gleam project that depends on `ssevents` by path. Run one with `cd examples/<name> && gleam run`. `just examples` builds and runs all of them with `--warnings-as-errors`, and CI runs it on every push.

| Example | What it shows |
|---|---|
| `quick_start` | Encode a few items, print the wire text, and decode it back. |
| `server_emit` | The response headers of an SSE endpoint and the chunks a server writes, one encoded item per write. |
| `streaming_consume` | Feed the incremental decoder chunks that split a byte order mark, an event and a line, and keep the `Last-Event-ID` and `retry` a client needs to reconnect. |

## Response headers

`ssevents` only produces and reads the bytes. The HTTP server has to send these headers for the stream to reach a browser as it is written:

| Header | Value | Why |
|---|---|---|
| `Content-Type` | `text/event-stream` | Required by the format. `ssevents.content_type()` returns it. |
| `Cache-Control` | `no-cache, no-transform` | Stops caches from storing the stream and proxies from compressing or rewriting it. |
| `Connection` | `keep-alive` | The stream is one long-lived HTTP/1.1 connection. HTTP/2 and HTTP/3 ignore this header. |
| `X-Accel-Buffering` | `no` | nginx and several ingress controllers buffer responses unless told not to. |

A buffered stream works locally and stalls behind a proxy, so also turn off response buffering and compression for the route in the proxy itself.

## Writing a stream

For a finite response, encode all items with `ssevents.encode_items` and send the string as the body. For a live stream, write `ssevents.encode_items([item])` or `ssevents.encode(event)` as one chunk per item, using the chunked or streaming body of your framework (`mist.Chunked`, for example). Each encoded event ends with a blank line, so the browser dispatches it as soon as the chunk arrives.

Some proxies close a connection that has been idle for 30 to 60 seconds. Writing `ssevents.comment("")` every 15 seconds or so keeps it open, and `EventSource` ignores comments.

## Browser client

Browsers have `EventSource` built in:

```javascript
const source = new EventSource("/events");

source.addEventListener("job.started", (e) => {
  // e.lastEventId is the last `id` the server sent.
  console.log("started", e.lastEventId, e.data);
});

source.onerror = () => {
  console.warn("disconnected; the browser will reconnect");
};
```

`EventSource` reconnects after a network error, waits for the last `retry` the server sent, and sends the last `id` in a `Last-Event-ID` request header. What that id means is up to the server. It can be a cursor into a durable event log, where the server resumes after it, or a sequence number, where the server replays newer events from a recent buffer.

## Reading a stream in Gleam

A Gleam client, on either target, gives each chunk of the response body to `ssevents.push` and calls `ssevents.finish` when the body ends. `ssevents.update_reconnect` keeps the `id` and `retry` to use for the next connection, as `streaming_consume` shows.
