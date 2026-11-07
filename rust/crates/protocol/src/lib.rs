//! watch-together room protocol v1: the Rust view of `protocol/room.schema.json`.
//!
//! Serde types, `item_ref` parsing, position math and inbound message parsing. No I/O.

mod item_ref;
mod message;
mod types;

pub use item_ref::{ITEM_REF_PATTERN, ItemRef, is_item_ref};
pub use message::{
    ClientInfo, ClientMsg, INTENT_REJECTED, Intent, IntentError, Meta, ParseError, PresenceAction,
    ServerMsg, Snapshot, as_safe_integer, encode,
};
pub use types::{MAX_SAFE_INTEGER, Member, Observed, Playback, QueueItem};
