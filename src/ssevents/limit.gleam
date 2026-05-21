//// Parser and decoder safety limits.
////
//// These values bound memory growth for the incremental decoder. The
//// `new` constructor rejects nonsensical values with a panic so callers
//// do not silently run with ineffective limits. For dynamic input
//// (config / env / framework), use `new_checked` and surface
//// `LimitConfigError.NonPositiveLimit` through your normal result
//// chain.

import gleam/bool
import gleam/result

pub opaque type Limits {
  Limits(
    max_line_bytes: Int,
    max_event_bytes: Int,
    max_data_lines: Int,
    max_retry_value: Int,
    /// When `True`, the decoder surfaces `Error(InvalidRetry(_))` for
    /// `retry:` values whose integer form is above `max_retry_value`.
    /// When `False` (the default), the decoder silently drops the
    /// offending `retry:` field to `None` and the surrounding event
    /// still dispatches — mirroring the encoder's `retry_clamp/2`
    /// posture and WHATWG SSE's "lenient parser" thesis (#95).
    strict_retry_cap: Bool,
  )
}

/// Why a checked limit constructor refused its argument.
///
/// `field` names the offending parameter so a single handler can
/// produce meaningful diagnostics across many checked constructors;
/// `given` carries the rejected value.
pub type LimitConfigError {
  NonPositiveLimit(field: String, given: Int)
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
    strict_retry_cap: False,
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
    strict_retry_cap: False,
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

/// Read the `strict_retry_cap` flag from a `Limits` value.
///
/// When `True`, the decoder errors with `InvalidRetry(_)` on `retry:`
/// values above `max_retry_value`; when `False` (the default), it
/// silently drops the offending field to `None` and the surrounding
/// event still dispatches. See `with_strict_retry_cap/2`. (#95)
pub fn strict_retry_cap(limits: Limits) -> Bool {
  let Limits(strict_retry_cap:, ..) = limits
  strict_retry_cap
}

/// Toggle the decoder's `retry:` cap-overrun posture.
///
/// Defaults to `False` (lenient): a `retry:` value whose integer form
/// exceeds `max_retry_value` is silently dropped to `None` so the
/// surrounding event still dispatches, mirroring the encoder's
/// `retry_clamp/2` and matching WHATWG SSE's lenient parser thesis.
/// Opt into `True` when downstream code needs to detect adversarial
/// retry values explicitly. (#95)
pub fn with_strict_retry_cap(limits: Limits, strict: Bool) -> Limits {
  Limits(..limits, strict_retry_cap: strict)
}

/// Alias of `max_event_bytes/1`. Reads the per-event byte cap the
/// decoder uses to reject oversize events with
/// `Error(EventTooLarge(_))`. Provided so callers can stay in the
/// `with_max_event_size` / `max_event_size` spelling pair when
/// raising the limit explicitly. (#96)
pub fn max_event_size(limits: Limits) -> Int {
  max_event_bytes(limits)
}

/// Override the per-event byte cap on a `Limits` value.
///
/// `ssevents.decode/1` runs with `default_max_event_bytes` (65_536) and
/// fails the whole stream with `Error(EventTooLarge(65_536))` for any
/// event above that cap — symmetric with `max_line_bytes` /
/// `max_data_lines`, but asymmetric with the encoder side which never
/// rejects an event for sheer size. A caller that knowingly emits a
/// 100 KB event and pipes it back through the decoder needs to raise
/// the cap explicitly:
///
/// ```gleam
/// let limits =
///   ssevents.default_limits()
///   |> ssevents.with_max_event_size(200_000)
/// ssevents.decode_with_limits(wire, limits: limits)
/// ```
///
/// The default `decode/1` deliberately keeps the 65_536-byte ceiling
/// as a memory-bound safety net for untrusted input; reach for
/// `decode_with_limits` + `with_max_event_size` when the input is
/// trusted and known to be larger. Panics on `bytes < 1` to mirror
/// `new/4`'s posture. (#96)
pub fn with_max_event_size(limits: Limits, bytes: Int) -> Limits {
  case bytes < 1 {
    True -> panic as "max_event_size must be >= 1"
    False -> Nil
  }
  Limits(..limits, max_event_bytes: bytes)
}

/// Like `new`, but returns the argument-validation failure as a
/// `Result` instead of panicking. Use this when limit values come
/// from configuration, environment variables, or other dynamic
/// sources where a malformed value is a recoverable runtime
/// condition rather than a programmer error.
///
/// On success the returned `Limits` is identical to what `new`
/// would return for the same arguments.
pub fn new_checked(
  max_line_bytes max_line_bytes: Int,
  max_event_bytes max_event_bytes: Int,
  max_data_lines max_data_lines: Int,
  max_retry_value max_retry_value: Int,
) -> Result(Limits, LimitConfigError) {
  use _ <- result.try(check_min("max_line_bytes", max_line_bytes, 1))
  use _ <- result.try(check_min("max_event_bytes", max_event_bytes, 1))
  use _ <- result.try(check_min("max_data_lines", max_data_lines, 1))
  use _ <- result.try(check_min("max_retry_value", max_retry_value, 0))
  Ok(Limits(
    max_line_bytes: max_line_bytes,
    max_event_bytes: max_event_bytes,
    max_data_lines: max_data_lines,
    max_retry_value: max_retry_value,
    strict_retry_cap: False,
  ))
}

fn check_min(
  field: String,
  value: Int,
  minimum: Int,
) -> Result(Nil, LimitConfigError) {
  use <- bool.guard(value < minimum, Error(NonPositiveLimit(field, value)))
  Ok(Nil)
}
