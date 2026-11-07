use serde::{Deserialize, Serialize, Serializer};

/// `Number.MAX_SAFE_INTEGER`: the wire is JSON and clients are JS/Dart, so integers beyond this
/// are not trusted.
pub const MAX_SAFE_INTEGER: i64 = (1 << 53) - 1;

/// The playback anchor. Position is derived, never sent as a command.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Playback {
    pub item_ref: String,
    /// Server time at which `position_ms` was true.
    pub anchor_server_ms: i64,
    pub position_ms: i64,
    #[serde(serialize_with = "js_number")]
    pub rate: f64,
    pub paused: bool,
}

impl Playback {
    /// `paused ? position_ms : position_ms + (now - anchor_server_ms) * rate`, rounded like JS
    /// `Math.round` (half towards +∞) and clamped at 0.
    pub fn position_at(&self, now_ms: i64) -> i64 {
        if self.paused {
            return self.position_ms;
        }
        let elapsed = now_ms.saturating_sub(self.anchor_server_ms) as f64;
        let advanced = (elapsed * self.rate + 0.5).floor() as i64;
        self.position_ms.saturating_add(advanced).max(0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueItem {
    pub item_ref: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Member {
    pub user_id: String,
    pub name: String,
}

/// What a client observed about its own sync, from a `report`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Observed {
    pub offset_ms: f64,
    pub rtt_ms: f64,
    pub drift_ms: f64,
    pub source: String,
}

/// Serializes integral floats as JSON integers, like `JSON.stringify`: `rate` goes out as `1`,
/// matching the TypeScript server byte for byte.
fn js_number<S: Serializer>(x: &f64, s: S) -> Result<S::Ok, S::Error> {
    if x.fract() == 0.0 && x.abs() <= MAX_SAFE_INTEGER as f64 {
        s.serialize_i64(*x as i64)
    } else {
        s.serialize_f64(*x)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pb(position_ms: i64, anchor_server_ms: i64, rate: f64, paused: bool) -> Playback {
        Playback {
            item_ref: "yt:dQw4w9WgXcQ".into(),
            anchor_server_ms,
            position_ms,
            rate,
            paused,
        }
    }

    #[test]
    fn position_at_follows_the_anchor() {
        assert_eq!(pb(1000, 0, 1.0, true).position_at(5000), 1000);
        assert_eq!(pb(1000, 0, 1.0, false).position_at(5000), 6000);
        assert_eq!(pb(1000, 0, 2.0, false).position_at(500), 2000);
        // Anchor in the future (clock skew) never yields a negative position.
        assert_eq!(pb(0, 1000, 1.0, false).position_at(0), 0);
    }

    #[test]
    fn position_at_rounds_like_js_math_round() {
        // Math.round(1.5) === 2, Math.round(-0.5) === -0, Math.round(-1.5) === -1.
        assert_eq!(pb(10, 0, 1.5, false).position_at(1), 12);
        assert_eq!(pb(10, 1, 0.5, false).position_at(0), 10);
        assert_eq!(pb(10, 1, 1.5, false).position_at(0), 9);
    }

    #[test]
    fn integral_rate_serializes_as_an_integer() {
        let json = serde_json::to_string(&pb(0, 0, 1.0, false)).unwrap();
        assert!(json.contains(r#""rate":1,"#), "{json}");
        let json = serde_json::to_string(&pb(0, 0, 1.25, false)).unwrap();
        assert!(json.contains(r#""rate":1.25,"#), "{json}");
    }
}
