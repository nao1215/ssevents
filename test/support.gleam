//// Builders for tests whose names, ids and comments are known to be one
//// line, so the `Result` of the real builders is in the way.

import ssevents

pub fn named(name: String, data: String) -> ssevents.Event {
  let assert Ok(event) = ssevents.named(name, data)
  event
}

pub fn id(event: ssevents.Event, id: String) -> ssevents.Event {
  let assert Ok(event) = ssevents.id(event, id)
  event
}

pub fn comment(text: String) -> ssevents.Item {
  let assert Ok(item) = ssevents.comment(text)
  item
}
