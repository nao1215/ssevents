//// Parser and decoder safety limits.
////
//// These values bound memory growth for the incremental decoder. Each
//// constructor rejects nonsensical values with a panic so callers do
//// not silently run with ineffective limits.

pub opaque type Limits {
  Limits(
    max_line_bytes: Int,
    max_event_bytes: Int,
    max_data_lines: Int,
    max_retry_value: Int,
  )
}

pub const default_max_line_bytes = 8192

pub const default_max_event_bytes = 65_536

pub const default_max_data_lines = 1024

pub const default_max_retry_value = 86_400_000

pub fn default() -> Limits {
  Limits(
    max_line_bytes: default_max_line_bytes,
    max_event_bytes: default_max_event_bytes,
    max_data_lines: default_max_data_lines,
    max_retry_value: default_max_retry_value,
  )
}

pub fn new(
  max_line_bytes max_line_bytes: Int,
  max_event_bytes max_event_bytes: Int,
  max_data_lines max_data_lines: Int,
  max_retry_value max_retry_value: Int,
) -> Limits {
  case max_line_bytes < 1 {
    True -> panic as "max_line_bytes must be >= 1"
    False -> Nil
  }
  case max_event_bytes < 1 {
    True -> panic as "max_event_bytes must be >= 1"
    False -> Nil
  }
  case max_data_lines < 1 {
    True -> panic as "max_data_lines must be >= 1"
    False -> Nil
  }
  case max_retry_value < 0 {
    True -> panic as "max_retry_value must be >= 0"
    False -> Nil
  }
  Limits(
    max_line_bytes: max_line_bytes,
    max_event_bytes: max_event_bytes,
    max_data_lines: max_data_lines,
    max_retry_value: max_retry_value,
  )
}

pub fn max_line_bytes(limits: Limits) -> Int {
  let Limits(max_line_bytes:, ..) = limits
  max_line_bytes
}

pub fn max_event_bytes(limits: Limits) -> Int {
  let Limits(max_event_bytes:, ..) = limits
  max_event_bytes
}

pub fn max_data_lines(limits: Limits) -> Int {
  let Limits(max_data_lines:, ..) = limits
  max_data_lines
}

pub fn max_retry_value(limits: Limits) -> Int {
  let Limits(max_retry_value:, ..) = limits
  max_retry_value
}
