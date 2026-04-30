import gleam/string
import gleeunit/should
import ssevents
import ssevents/error.{EventTooLarge, InvalidField, InvalidRetry}
import ssevents/event
import ssevents/limit
import ssevents/validate

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

pub fn max_data_bytes_checked_ok_within_limit_test() {
  let evt = event.new("hi")
  let assert Ok(inner) = validate.max_data_bytes_checked(evt, max: 10)
  inner |> should.equal(Ok(evt))
}

pub fn max_data_bytes_checked_ok_event_too_large_test() {
  let evt = event.new("hellohello")
  let assert Ok(inner) = validate.max_data_bytes_checked(evt, max: 5)
  inner |> should.equal(Error(EventTooLarge(5)))
}

pub fn max_data_bytes_checked_negative_max_returns_config_error_test() {
  let evt = event.new("ok")
  case validate.max_data_bytes_checked(evt, max: -1) {
    Error(limit.NonPositiveLimit(field: field, given: given)) -> {
      field |> should.equal("max")
      given |> should.equal(-1)
    }
    Ok(_) -> should.fail()
  }
}
