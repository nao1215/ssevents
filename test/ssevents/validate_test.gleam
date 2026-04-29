import gleam/string
import gleeunit/should
import ssevents
import ssevents/error.{InvalidField, InvalidRetry}

pub fn validation_helpers_test() {
  ssevents.validate_event_name("ok") |> should.equal(Ok("ok"))
  ssevents.validate_event_name("") |> should.equal(Ok(""))
  ssevents.validate_event_name(string.repeat("a", times: 128))
  |> should.equal(Ok(string.repeat("a", times: 128)))
  ssevents.validate_event_name("event\nname")
  |> should.equal(Error(InvalidField("event")))
  ssevents.validate_event_name("event\rname")
  |> should.equal(Error(InvalidField("event")))
  ssevents.validate_event_name("event\u{0}name")
  |> should.equal(Error(InvalidField("event")))

  ssevents.validate_id("id-1") |> should.equal(Ok("id-1"))
  ssevents.validate_id("") |> should.equal(Ok(""))
  ssevents.validate_id(string.repeat("z", times: 128))
  |> should.equal(Ok(string.repeat("z", times: 128)))
  ssevents.validate_id("id\nname")
  |> should.equal(Error(InvalidField("id")))
  ssevents.validate_id("id\rname")
  |> should.equal(Error(InvalidField("id")))
  ssevents.validate_id("id\u{0}name")
  |> should.equal(Error(InvalidField("id")))

  ssevents.validate_retry(0) |> should.equal(Ok(0))
  ssevents.validate_retry(-1) |> should.equal(Error(InvalidRetry("-1")))
}
