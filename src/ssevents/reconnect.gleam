//// Reconnection metadata tracking.

import gleam/option.{type Option, None, Some}
import ssevents/event

pub opaque type ReconnectState {
  ReconnectState(last_event_id: Option(String), retry: Option(Int))
}

pub fn new() -> ReconnectState {
  ReconnectState(last_event_id: None, retry: None)
}

pub fn update(state: ReconnectState, item: event.Item) -> ReconnectState {
  case item {
    event.Comment(_) -> state
    event.EventItem(ev) ->
      ReconnectState(
        last_event_id: option.or(event.id_of(ev), state.last_event_id),
        retry: option.or(event.retry_of(ev), state.retry),
      )
  }
}

pub fn last_event_id(state: ReconnectState) -> Option(String) {
  state.last_event_id
}

pub fn retry(state: ReconnectState) -> Option(Int) {
  state.retry
}

pub fn last_event_id_header(state: ReconnectState) -> Option(#(String, String)) {
  case state.last_event_id {
    Some(id) -> Some(#("Last-Event-ID", id))
    None -> None
  }
}
