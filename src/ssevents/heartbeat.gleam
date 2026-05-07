//// Comment and heartbeat item helpers.

import ssevents/event.{type Item}

pub const heartbeat_text = "heartbeat"

pub fn comment(text: String) -> Item {
  event.comment_item(text)
}

pub fn heartbeat() -> Item {
  event.comment_item(heartbeat_text)
}
