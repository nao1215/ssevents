import gleam/option.{Some}
import gleeunit/should
import ssevents

pub fn reconnect_state_tracks_last_id_and_retry_test() {
  let state =
    ssevents.new_reconnect_state()
    |> ssevents.update_reconnect(ssevents.comment("ignore"))
    |> ssevents.update_reconnect(
      ssevents.named("job", "payload")
      |> ssevents.id("cursor-99")
      |> ssevents.retry(1500)
      |> ssevents.event_item,
    )

  ssevents.last_event_id(state) |> should.equal(Some("cursor-99"))
  ssevents.retry_interval(state) |> should.equal(Some(1500))
  ssevents.last_event_id_header(state)
  |> should.equal(Some(#("Last-Event-ID", "cursor-99")))
}
