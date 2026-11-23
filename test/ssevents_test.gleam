import gleeunit
import gleeunit/should
import ssevents.{EventTooLarge, InvalidUtf8, LineTooLong, TooManyDataLines}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn encode_decode_roundtrip_items_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.named("job.started", "hello\nworld")
      |> ssevents.id("cursor-1")
      |> ssevents.retry(2000)
      |> ssevents.EventItem,
    ssevents.EventItem(ssevents.new("")),
  ]

  let wire = ssevents.encode_items(items)
  ssevents.decode(<<wire:utf8>>, ssevents.default_limits)
  |> should.equal(Ok(items))
}

pub fn content_type_test() {
  ssevents.content_type() |> should.equal("text/event-stream")
}

pub fn error_to_string_test() {
  ssevents.error_to_string(InvalidUtf8)
  |> should.equal("invalid UTF-8 in SSE input")
  ssevents.error_to_string(LineTooLong(limit: 8))
  |> should.equal("line exceeds configured byte limit 8")
  ssevents.error_to_string(EventTooLarge(limit: 9))
  |> should.equal("event exceeds configured byte limit 9")
  ssevents.error_to_string(TooManyDataLines(limit: 2))
  |> should.equal("event exceeds configured data-line limit 2")
}
