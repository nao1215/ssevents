import gleeunit/should
import ssevents/limit

pub fn new_checked_ok_returns_limits_test() {
  let assert Ok(l) =
    limit.new_checked(
      max_line_bytes: 100,
      max_event_bytes: 1000,
      max_data_lines: 10,
      max_retry_value: 5000,
    )
  l |> limit.max_line_bytes |> should.equal(100)
  l |> limit.max_event_bytes |> should.equal(1000)
  l |> limit.max_data_lines |> should.equal(10)
  l |> limit.max_retry_value |> should.equal(5000)
}

pub fn new_checked_rejects_zero_max_line_bytes_test() {
  case
    limit.new_checked(
      max_line_bytes: 0,
      max_event_bytes: 1000,
      max_data_lines: 10,
      max_retry_value: 5000,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: g)) -> {
      f |> should.equal("max_line_bytes")
      g |> should.equal(0)
    }
    Ok(_) -> should.fail()
  }
}

pub fn new_checked_rejects_negative_max_event_bytes_test() {
  case
    limit.new_checked(
      max_line_bytes: 100,
      max_event_bytes: -1,
      max_data_lines: 10,
      max_retry_value: 5000,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: g)) -> {
      f |> should.equal("max_event_bytes")
      g |> should.equal(-1)
    }
    Ok(_) -> should.fail()
  }
}

pub fn new_checked_rejects_zero_max_data_lines_test() {
  case
    limit.new_checked(
      max_line_bytes: 100,
      max_event_bytes: 1000,
      max_data_lines: 0,
      max_retry_value: 5000,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: _)) ->
      f |> should.equal("max_data_lines")
    Ok(_) -> should.fail()
  }
}

pub fn new_checked_rejects_negative_max_retry_value_test() {
  case
    limit.new_checked(
      max_line_bytes: 100,
      max_event_bytes: 1000,
      max_data_lines: 10,
      max_retry_value: -1,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: _)) ->
      f |> should.equal("max_retry_value")
    Ok(_) -> should.fail()
  }
}

pub fn new_checked_allows_zero_max_retry_value_test() {
  // max_retry_value's panic threshold is < 0, so 0 must be accepted.
  let assert Ok(l) =
    limit.new_checked(
      max_line_bytes: 100,
      max_event_bytes: 1000,
      max_data_lines: 10,
      max_retry_value: 0,
    )
  l |> limit.max_retry_value |> should.equal(0)
}
