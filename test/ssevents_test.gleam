import gleeunit
import gleeunit/should
import ssevents
import ssevents/error.{InvalidRetry, InvalidUtf8}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn package_name_matches_repository_test() {
  ssevents.package_name
  |> should.equal("ssevents")
}

pub fn encode_decode_roundtrip_items_test() {
  let items = [
    ssevents.comment("meta"),
    ssevents.named("job.started", "hello\nworld")
      |> ssevents.id("cursor-1")
      |> ssevents.retry(2000)
      |> ssevents.event_item,
    ssevents.new("") |> ssevents.event_item,
  ]

  let assert Ok(decoded) = items |> ssevents.encode_items |> ssevents.decode
  decoded |> should.equal(items)
}

pub fn facade_error_to_string_test() {
  ssevents.error_to_string(InvalidUtf8)
  |> should.equal(error.to_string(InvalidUtf8))
  ssevents.error_to_string(InvalidRetry("nope"))
  |> should.equal(error.to_string(InvalidRetry("nope")))
}
