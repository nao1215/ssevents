//// Event and item domain values.
////
//// `Event` is opaque so the package can evolve its representation
//// without a breaking change. Construct via `new`, `from_parts`, and
//// the builder helpers. `Item` stays transparent because callers and
//// helper modules frequently pattern match on whether a stream element
//// is an event or a comment.

import gleam/option.{type Option, None, Some}

pub opaque type Event {
  Event(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

pub type Item {
  EventItem(Event)
  Comment(String)
}

pub fn new(data: String) -> Event {
  Event(event: None, data: data, id: None, retry: None)
}

pub fn from_parts(
  event_name event_name: Option(String),
  data data: String,
  id id: Option(String),
  retry retry: Option(Int),
) -> Event {
  Event(event: event_name, data: data, id: id, retry: retry)
}

pub fn message(data: String) -> Event {
  new(data)
}

pub fn named(name: String, data: String) -> Event {
  new(data) |> event(name)
}

pub fn event(event: Event, name: String) -> Event {
  Event(event: Some(name), data: event.data, id: event.id, retry: event.retry)
}

pub fn id(event: Event, id: String) -> Event {
  Event(event: event.event, data: event.data, id: Some(id), retry: event.retry)
}

pub fn retry(event: Event, milliseconds: Int) -> Event {
  Event(
    event: event.event,
    data: event.data,
    id: event.id,
    retry: Some(milliseconds),
  )
}

pub fn data(event: Event, data: String) -> Event {
  Event(event: event.event, data: data, id: event.id, retry: event.retry)
}

pub fn name_of(event: Event) -> Option(String) {
  event.event
}

pub fn data_of(event: Event) -> String {
  event.data
}

pub fn id_of(event: Event) -> Option(String) {
  event.id
}

pub fn retry_of(event: Event) -> Option(Int) {
  event.retry
}

pub fn event_item(event: Event) -> Item {
  EventItem(event)
}
