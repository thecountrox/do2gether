//! Client view of server time: four-timestamp pings, median offset over a burst of samples.
//!
//! Local time is a monotonic clock anchored to the wall clock once at startup, so wall-clock
//! steps (NTP) never move `server_now()`; only a new burst does.

use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub const SAMPLES: usize = 10;

pub struct Clock {
    origin: Instant,
    origin_ms: f64,
    /// `server - local`, from the last complete burst. Until then: 0, i.e. trust the wall clock.
    offset_ms: f64,
    rtt_ms: f64,
    ready: bool,
    burst: Vec<(f64, f64)>,
}

impl Clock {
    pub fn new() -> Self {
        let wall = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64() * 1000.0);
        Clock {
            origin: Instant::now(),
            origin_ms: wall,
            offset_ms: 0.0,
            rtt_ms: 0.0,
            ready: false,
            burst: Vec::with_capacity(SAMPLES),
        }
    }

    pub fn local_ms(&self) -> f64 {
        self.origin_ms + self.origin.elapsed().as_secs_f64() * 1000.0
    }

    pub fn server_now(&self) -> i64 {
        (self.local_ms() + self.offset_ms).round() as i64
    }

    pub fn offset_ms(&self) -> f64 {
        self.offset_ms
    }

    pub fn rtt_ms(&self) -> f64 {
        self.rtt_ms
    }

    /// True once the first burst has completed.
    pub fn ready(&self) -> bool {
        self.ready
    }

    /// Adds one sample to the current burst. Returns true when the burst is complete, at which
    /// point the median offset (and median RTT) replace the previous estimate.
    pub fn ingest(&mut self, t0: f64, t1: f64, t2: f64, t3: f64) -> bool {
        self.burst.push(sample(t0, t1, t2, t3));
        if self.burst.len() < SAMPLES {
            return false;
        }
        let (offsets, rtts): (Vec<f64>, Vec<f64>) = self.burst.drain(..).unzip();
        self.offset_ms = median(offsets);
        self.rtt_ms = median(rtts);
        self.ready = true;
        true
    }

    /// Drops a partial burst (a refresh restarts from zero samples).
    pub fn restart_burst(&mut self) {
        self.burst.clear();
    }
}

/// `(offset, rtt)` for one ping: `offset = ((t1 - t0) + (t2 - t3)) / 2`, `rtt = (t3 - t0) - (t2 - t1)`.
pub fn sample(t0: f64, t1: f64, t2: f64, t3: f64) -> (f64, f64) {
    (((t1 - t0) + (t2 - t3)) / 2.0, (t3 - t0) - (t2 - t1))
}

pub fn median(mut xs: Vec<f64>) -> f64 {
    xs.sort_by(f64::total_cmp);
    let n = xs.len();
    if n == 0 {
        0.0
    } else if n % 2 == 1 {
        xs[n / 2]
    } else {
        (xs[n / 2 - 1] + xs[n / 2]) / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_timestamp_sample() {
        // Server 100 ms ahead, 10 ms each way, 2 ms processing.
        assert_eq!(sample(0.0, 110.0, 112.0, 22.0), (100.0, 20.0));
    }

    #[test]
    fn burst_takes_the_median_and_ignores_outliers() {
        let mut c = Clock::new();
        assert!(!c.ready());
        for i in 0..SAMPLES - 1 {
            // One outlier with a 5 s offset; the rest say +50 ms with 4 ms RTT.
            let skew = if i == 3 { 5000.0 } else { 50.0 };
            assert!(!c.ingest(0.0, 2.0 + skew, 2.0 + skew, 4.0));
        }
        assert!(c.ingest(0.0, 52.0, 52.0, 4.0));
        assert!(c.ready());
        assert_eq!(c.offset_ms(), 50.0);
        assert_eq!(c.rtt_ms(), 4.0);
        let drift = c.server_now() as f64 - (c.local_ms() + 50.0);
        assert!(drift.abs() <= 1.0, "{drift}");
        assert_eq!(median(vec![3.0, 1.0, 2.0]), 2.0);
        assert_eq!(median(vec![]), 0.0);
    }
}
