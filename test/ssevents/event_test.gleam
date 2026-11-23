import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{CommentItem, EventItem}

fn decode(text: String) -> Result(List(ssevents.Item), ssevents.SseError) {
  ssevents.decode(<<text:utf8>>, ssevents.default_limits)
}

pub fn event_builder_accessors_test() {
  let event =
    ssevents.named("job.update", "payload")
    |> ssevents.id("job-1")
    |> ssevents.retry(5000)

  ssevents.name_of(event) |> should.equal(Some("job.update"))
  ssevents.data_of(event) |> should.equal("payload")
  ssevents.id_of(event) |> should.equal(Some("job-1"))
  ssevents.retry_of(event) |> should.equal(Some(5000))
}

pub fn new_has_no_optional_fields_test() {
  let event = ssevents.new("payload")
  ssevents.name_of(event) |> should.equal(None)
  ssevents.id_of(event) |> should.equal(None)
  ssevents.retry_of(event) |> should.equal(None)
}

// CR, LF and NUL in a name or an id cannot survive the wire format, so
// they are removed when the event is built.

pub fn named_strips_lf_test() {
  ssevents.named("foo\nbar", "payload")
  |> ssevents.name_of
  |> should.equal(Some("foobar"))
}

pub fn named_strips_cr_test() {
  ssevents.named("foo\rbar", "payload")
  |> ssevents.name_of
  |> should.equal(Some("foobar"))
}

pub fn named_strips_nul_test() {
  ssevents.named("foo\u{0000}bar", "payload")
  |> ssevents.name_of
  |> should.equal(Some("foobar"))
}

pub fn id_strips_lf_test() {
  ssevents.new("payload")
  |> ssevents.id("a\nb")
  |> ssevents.id_of
  |> should.equal(Some("ab"))
}

pub fn id_strips_crlf_pair_test() {
  ssevents.new("payload")
  |> ssevents.id("a\r\nb")
  |> ssevents.id_of
  |> should.equal(Some("ab"))
}

pub fn id_strips_nul_test() {
  ssevents.new("payload")
  |> ssevents.id("with\u{0000}nul")
  |> ssevents.id_of
  |> should.equal(Some("withnul"))
}

pub fn new_normalises_lone_cr_in_data_to_lf_test() {
  // A CR in `data` ends a line on the wire, exactly like LF.
  ssevents.new("a\rb") |> ssevents.data_of |> should.equal("a\nb")
}

pub fn new_strips_cr_from_crlf_pair_in_data_test() {
  ssevents.new("a\r\nb") |> ssevents.data_of |> should.equal("a\nb")
}

pub fn new_strips_nul_from_data_test() {
  ssevents.new("hello\u{0000}world")
  |> ssevents.data_of
  |> should.equal("helloworld")
}

pub fn new_preserves_lf_in_data_test() {
  ssevents.new("first\nsecond")
  |> ssevents.data_of
  |> should.equal("first\nsecond")
}

pub fn data_round_trips_after_cr_sanitisation_test() {
  let event = ssevents.new("a\r\nb")
  let wire = ssevents.encode(event)
  decode(wire) |> should.equal(Ok([EventItem(event)]))
}

pub fn encode_then_decode_round_trips_after_sanitisation_test() {
  let original =
    ssevents.named("noti\nce", "payload") |> ssevents.id("evt\u{0000}1")
  let wire = ssevents.encode(original)
  decode(wire) |> should.equal(Ok([EventItem(original)]))
}

// `retry` keeps values from 0 to 86_400_000 and removes the field for
// anything else, so the default decoder reads back what was written.

pub fn retry_drops_value_above_default_max_test() {
  ssevents.new("payload")
  |> ssevents.retry(1_000_000_000)
  |> ssevents.retry_of
  |> should.equal(None)
}

pub fn retry_keeps_zero_test() {
  ssevents.new("payload")
  |> ssevents.retry(0)
  |> ssevents.retry_of
  |> should.equal(Some(0))
}

pub fn retry_keeps_default_max_boundary_test() {
  ssevents.new("payload")
  |> ssevents.retry(86_400_000)
  |> ssevents.retry_of
  |> should.equal(Some(86_400_000))
  ssevents.new("payload")
  |> ssevents.retry(86_400_001)
  |> ssevents.retry_of
  |> should.equal(None)
}

pub fn retry_drops_negative_value_test() {
  ssevents.new("payload")
  |> ssevents.retry(-1)
  |> ssevents.retry_of
  |> should.equal(None)
}

pub fn retry_out_of_range_removes_an_earlier_value_test() {
  ssevents.new("payload")
  |> ssevents.retry(1000)
  |> ssevents.retry(-5)
  |> ssevents.retry_of
  |> should.equal(None)
}

pub fn encode_decode_round_trips_after_retry_sanitisation_test() {
  let huge = ssevents.new("x") |> ssevents.retry(1_000_000_000)
  decode(ssevents.encode(huge)) |> should.equal(Ok([EventItem(huge)]))
}

pub fn comment_strips_line_breaks_and_nul_test() {
  let assert CommentItem(comment) = ssevents.comment("a\r\nb\nc\rd\u{0000}e")
  ssevents.comment_text(comment) |> should.equal("abcde")
}

pub fn decoded_item_can_be_matched_through_one_import_test() {
  let assert Ok([first, ..]) = decode("event: job.update\ndata: hello\n\n")
  case first {
    EventItem(event) ->
      ssevents.name_of(event) |> should.equal(Some("job.update"))
    CommentItem(_) -> should.fail()
  }
}
