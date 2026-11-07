use std::time::{SystemTime, UNIX_EPOCH};

/// Server time in integer ms since the Unix epoch. Every timestamp the server emits comes from here.
pub fn server_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}
