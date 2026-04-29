//// Explicit error surface for `ssevents`.

import gleam/int

pub type SseError {
  InvalidUtf8
  LineTooLong(limit: Int)
  EventTooLarge(limit: Int)
  TooManyDataLines(limit: Int)
  InvalidRetry(String)
  InvalidField(String)
  UnexpectedEnd
  UnsupportedFeature(String)
}

pub fn to_string(error: SseError) -> String {
  case error {
    InvalidUtf8 -> "invalid UTF-8 in SSE input"
    LineTooLong(limit) ->
      "line exceeds configured byte limit " <> int.to_string(limit)
    EventTooLarge(limit) ->
      "event exceeds configured byte limit " <> int.to_string(limit)
    TooManyDataLines(limit) ->
      "event exceeds configured data-line limit " <> int.to_string(limit)
    InvalidRetry(value) -> "invalid retry field: " <> value
    InvalidField(field) -> "invalid SSE field: " <> field
    UnexpectedEnd -> "unexpected end of input"
    UnsupportedFeature(feature) -> "unsupported feature: " <> feature
  }
}
