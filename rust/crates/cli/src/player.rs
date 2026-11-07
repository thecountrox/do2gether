//! The session's view of a player: mpv for real, or a wall-clock model of it for tests.

use std::io;
use std::time::Instant;

use crate::mpv::Mpv;

pub enum Player {
    Mpv { mpv: Box<Mpv>, file: String },
    Sim(Sim),
}

impl Player {
    pub fn source(&self) -> &'static str {
        match self {
            Player::Mpv { .. } => "mpv",
            Player::Sim(_) => "simulate",
        }
    }

    /// Loads the file (paused) if nothing is loaded. Returns true if it just loaded.
    pub async fn ensure_loaded(&mut self) -> io::Result<bool> {
        match self {
            Player::Mpv { mpv, file } => {
                if !mpv.idle().await? {
                    return Ok(false);
                }
                mpv.load(file).await?;
                Ok(true)
            }
            Player::Sim(sim) => Ok(sim.load()),
        }
    }

    /// `None` while nothing is loaded.
    pub async fn time_pos_ms(&mut self) -> io::Result<Option<f64>> {
        match self {
            Player::Mpv { mpv, .. } => mpv.time_pos_ms().await,
            Player::Sim(sim) => Ok(sim.time_pos_ms()),
        }
    }

    pub async fn seek_ms(&mut self, ms: i64) -> io::Result<()> {
        match self {
            Player::Mpv { mpv, .. } => mpv.seek_ms(ms).await,
            Player::Sim(sim) => {
                sim.seek_ms(ms);
                Ok(())
            }
        }
    }

    pub async fn set_pause(&mut self, paused: bool) -> io::Result<()> {
        match self {
            Player::Mpv { mpv, .. } => mpv.set_pause(paused).await,
            Player::Sim(sim) => {
                sim.set_pause(paused);
                Ok(())
            }
        }
    }

    pub async fn set_speed(&mut self, speed: f64) -> io::Result<()> {
        match self {
            Player::Mpv { mpv, .. } => mpv.set_speed(speed).await,
            Player::Sim(sim) => {
                sim.set_speed(speed);
                Ok(())
            }
        }
    }

    /// `Some(reason)` if the player went away on its own.
    pub fn exited(&mut self) -> Option<String> {
        match self {
            Player::Mpv { mpv, .. } => mpv.exited(),
            Player::Sim(_) => None,
        }
    }

    pub async fn shutdown(self) {
        if let Player::Mpv { mpv, .. } = self {
            mpv.quit().await;
        }
    }
}

/// A virtual player: position advances with the local monotonic clock times `speed`. Like mpv
/// it starts idle, loads paused at 0, and seeks/pauses/speeds instantly.
pub struct Sim {
    loaded: bool,
    pos_ms: f64,
    at: Instant,
    speed: f64,
    paused: bool,
}

impl Default for Sim {
    fn default() -> Self {
        Sim {
            loaded: false,
            pos_ms: 0.0,
            at: Instant::now(),
            speed: 1.0,
            paused: true,
        }
    }
}

impl Sim {
    fn load(&mut self) -> bool {
        if self.loaded {
            return false;
        }
        *self = Sim {
            loaded: true,
            speed: self.speed,
            ..Sim::default()
        };
        true
    }

    fn now_ms(&self) -> f64 {
        if self.paused {
            self.pos_ms
        } else {
            self.pos_ms + self.at.elapsed().as_secs_f64() * 1000.0 * self.speed
        }
    }

    fn rebase(&mut self) {
        self.pos_ms = self.now_ms();
        self.at = Instant::now();
    }

    fn time_pos_ms(&self) -> Option<f64> {
        self.loaded.then(|| self.now_ms())
    }

    fn seek_ms(&mut self, ms: i64) {
        self.pos_ms = ms as f64;
        self.at = Instant::now();
    }

    fn set_pause(&mut self, paused: bool) {
        self.rebase();
        self.paused = paused;
    }

    fn set_speed(&mut self, speed: f64) {
        self.rebase();
        self.speed = speed;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn sim_models_load_seek_pause_and_speed() {
        let mut s = Sim::default();
        assert_eq!(s.time_pos_ms(), None);
        assert!(s.load());
        assert!(!s.load());
        assert_eq!(s.time_pos_ms(), Some(0.0));
        s.seek_ms(42_000);
        s.set_speed(2.0);
        s.set_pause(false);
        std::thread::sleep(Duration::from_millis(50));
        s.set_pause(true);
        let p = s.time_pos_ms().unwrap();
        assert!((42_100.0..42_200.0).contains(&p), "{p}");
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(s.time_pos_ms(), Some(p), "paused holds still");
    }
}
