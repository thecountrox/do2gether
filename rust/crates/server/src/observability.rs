//! Process-local counters and Prometheus/JSON snapshots.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::{AppState, lock};

#[derive(Default)]
pub(crate) struct Counters {
    intents: AtomicU64,
    rejects: AtomicU64,
    operations: Mutex<HashMap<(String, &'static str), Arc<AtomicU64>>>,
    codes: Mutex<HashMap<&'static str, Arc<AtomicU64>>>,
}

impl Counters {
    pub fn intent(&self, op: &str, result: &'static str) {
        self.intents.fetch_add(1, Ordering::Relaxed);
        let counter = lock(&self.operations)
            .entry((op.to_owned(), result))
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        counter.fetch_add(1, Ordering::Relaxed);
    }

    pub fn reject(&self, code: &'static str) {
        self.rejects.fetch_add(1, Ordering::Relaxed);
        let counter = lock(&self.codes)
            .entry(code)
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        counter.fetch_add(1, Ordering::Relaxed);
    }
}

#[derive(Serialize)]
pub(crate) struct RoomStats {
    room_id: String,
    rev: u64,
    members: usize,
    p50_drift_ms: Option<f64>,
    p95_drift_ms: Option<f64>,
    corrections: u64,
}

#[derive(Serialize)]
pub(crate) struct Totals {
    rooms: usize,
    clients: usize,
    intents: u64,
    rejects: u64,
}

#[derive(Serialize)]
pub(crate) struct Stats {
    rooms: Vec<RoomStats>,
    totals: Totals,
}

impl AppState {
    pub(crate) fn stats(&self) -> Stats {
        let rooms = self
            .rooms
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut clients = 0;
        let mut details: Vec<_> = rooms
            .values()
            .map(|shared| {
                let room = lock(shared);
                clients += room.client_count();
                let (p50_drift_ms, p95_drift_ms) = room.drift_quantiles();
                RoomStats {
                    room_id: room.id.clone(),
                    rev: room.rev,
                    members: room.member_count(),
                    p50_drift_ms,
                    p95_drift_ms,
                    corrections: room.corrections,
                }
            })
            .collect();
        details.sort_by(|a, b| a.room_id.cmp(&b.room_id));
        Stats {
            totals: Totals {
                rooms: details.len(),
                clients,
                intents: self.counters.intents.load(Ordering::Relaxed),
                rejects: self.counters.rejects.load(Ordering::Relaxed),
            },
            rooms: details,
        }
    }

    pub(crate) fn metrics(&self) -> String {
        let stats = self.stats();
        let mut lines = format!(
            "wt_rooms {}\nwt_clients {}\n",
            stats.totals.rooms, stats.totals.clients
        );
        let mut operations: Vec<_> = lock(&self.counters.operations)
            .iter()
            .map(|((op, result), count)| (op.clone(), *result, count.load(Ordering::Relaxed)))
            .collect();
        operations.sort();
        for (op, result, count) in operations {
            lines.push_str(&format!(
                "wt_intents_total{{op=\"{op}\",result=\"{result}\"}} {count}\n"
            ));
        }
        let mut codes: Vec<_> = lock(&self.counters.codes)
            .iter()
            .map(|(code, count)| (*code, count.load(Ordering::Relaxed)))
            .collect();
        codes.sort();
        for (code, count) in codes {
            lines.push_str(&format!("wt_rejects_total{{code=\"{code}\"}} {count}\n"));
        }
        for room in stats.rooms {
            // IDs are generated from lowercase base36 only.
            lines.push_str(&format!(
                "wt_room_members{{room=\"{}\"}} {}\n",
                room.room_id, room.members
            ));
            if let (Some(p50), Some(p95)) = (room.p50_drift_ms, room.p95_drift_ms) {
                lines.push_str(&format!(
                    "wt_drift_ms{{room=\"{}\",quantile=\"0.5\"}} {p50}\nwt_drift_ms{{room=\"{}\",quantile=\"0.95\"}} {p95}\n",
                    room.room_id, room.room_id
                ));
            }
        }
        let degraded = self.db_unavailable
            || self
                .rooms
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .values()
                .any(|room| lock(room).degraded);
        lines.push_str(&format!("wt_db_degraded {}\n", u8::from(degraded)));
        lines
    }
}
