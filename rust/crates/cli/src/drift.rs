//! Video drift policy (docs/00-spec.md, Sync rules): < 250 ms leave it, 250 ms–2 s nudge the
//! speed by 3 % for up to 2 s, beyond that seek. Never applied while paused.

use std::time::Duration;

pub const DEAD_BAND_MS: u64 = 250;
pub const SEEK_MS: u64 = 2000;
pub const NUDGE: f64 = 0.03;
pub const NUDGE_FOR: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Correction {
    None,
    /// Speed factor relative to the anchor's rate: `1 + NUDGE` when behind, `1 - NUDGE` when ahead.
    Rate(f64),
    Seek,
}

/// `drift_ms = player position - room position`. Intervals are half-open: 250 is a nudge,
/// 2000 is a seek.
pub fn decide(drift_ms: i64) -> Correction {
    let d = drift_ms.unsigned_abs();
    if d < DEAD_BAND_MS {
        Correction::None
    } else if d < SEEK_MS {
        Correction::Rate(if drift_ms < 0 {
            1.0 + NUDGE
        } else {
            1.0 - NUDGE
        })
    } else {
        Correction::Seek
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Correction::{None, Rate, Seek};

    #[test]
    fn policy_table_at_the_boundaries() {
        let table = [
            (0, None),
            (249, None),
            (250, Rate(0.97)),
            (1999, Rate(0.97)),
            (2000, Seek),
            (-249, None),
            (-250, Rate(1.03)),
            (-1999, Rate(1.03)),
            (-2000, Seek),
            (i64::MIN, Seek),
        ];
        for (drift, expected) in table {
            assert_eq!(decide(drift), expected, "drift {drift} ms");
        }
    }
}
