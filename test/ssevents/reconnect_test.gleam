import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import ssevents.{ReconnectState}

pub fn reconnect_state_tracks_last_id_and_retry_test() {
  let state =
    ReconnectState(last_event_id: None, retry: None)
    |> ssevents.update_reconnect(ssevents.comment("ignore"))
    |> ssevents.update_reconnect(
      ssevents.named("job", "payload")
      |> ssevents.id("cursor-99")
      |> ssevents.retry(1500)
      |> ssevents.EventItem,
    )

  state
  |> should.equal(ReconnectState(
    last_event_id: Some("cursor-99"),
    retry: Some(1500),
  ))
}

pub fn reconnect_state_keeps_retry_and_resets_on_empty_id_test() {
  let items = [
    ssevents.EventItem(
      ssevents.new("a") |> ssevents.id("1") |> ssevents.retry(10),
    ),
    ssevents.EventItem(ssevents.new("b")),
    ssevents.EventItem(ssevents.new("c") |> ssevents.id("")),
  ]
  list.fold(items, ReconnectState(None, None), ssevents.update_reconnect)
  |> should.equal(ReconnectState(last_event_id: None, retry: Some(10)))
}
