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
    event.EventItem(ev) -> {
      let last_event_id = case event.id_of(ev) {
        Some(id) -> Some(id)
        None -> state.last_event_id
      }

      let retry_value = case event.retry_of(ev) {
        Some(retry) -> Some(retry)
        None -> state.retry
      }

      ReconnectState(last_event_id: last_event_id, retry: retry_value)
    }
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
