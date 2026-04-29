//// Comment and heartbeat item helpers.

import ssevents/event.{type Item, Comment}

pub const heartbeat_text = "heartbeat"

pub fn comment(text: String) -> Item {
  Comment(text)
}

pub fn heartbeat() -> Item {
  Comment(heartbeat_text)
}
