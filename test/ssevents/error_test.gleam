import gleeunit/should
import ssevents/error.{InvalidRetry}

pub fn error_to_string_invalid_retry_test() {
  error.to_string(InvalidRetry("nope"))
  |> should.equal(
    "invalid retry value: \"nope\" (must be a non-negative integer)",
  )
  error.to_string(InvalidRetry("-1"))
  |> should.equal(
    "invalid retry value: \"-1\" (must be a non-negative integer)",
  )
}
