//! One joined room: clock bursts, anchor application, drift correction, reports, stdin intents.

use std::io;
use std::time::Duration;

use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::net::TcpStream;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use tokio::time::{Instant, MissedTickBehavior, interval, sleep_until};
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use wt_protocol::Playback;

use crate::clock::Clock;
use crate::drift::{self, Correction, DEAD_BAND_MS, NUDGE_FOR};
use crate::player::Player;
use crate::wire::{Inbound, Outbox};

pub type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

const POLL_EVERY: Duration = Duration::from_secs(1);
const REPORT_EVERY: Duration = Duration::from_secs(5);
const CLOCK_EVERY: Duration = Duration::from_secs(30);

enum Flow {
    Continue,
    Quit,
}

type Step = Result<Flow, String>;

pub struct Session {
    sink: SplitSink<Ws, Message>,
    out: Outbox,
    clock: Clock,
    player: Player,
    /// What `play` asks the room to play: the ref of our file.
    item_ref: String,
    rev: u64,
    /// The room's playback as last received. Applied once the first clock burst is done.
    anchor: Option<Playback>,
    /// The ping in flight: id and exact local send time.
    ping: Option<(String, f64)>,
    pings_sent: u64,
    nudge_until: Option<Instant>,
    drift_ms: Option<f64>,
    warned_ref: Option<String>,
}

impl Session {
    pub fn new(
        sink: SplitSink<Ws, Message>,
        out: Outbox,
        clock: Clock,
        player: Player,
        item_ref: String,
    ) -> Self {
        Session {
            sink,
            out,
            clock,
            player,
            item_ref,
            rev: 0,
            anchor: None,
            ping: None,
            pings_sent: 0,
            nudge_until: None,
            drift_ms: None,
            warned_ref: None,
        }
    }

    /// Says hello and runs until `q`, SIGINT/SIGTERM, or a fatal error; then quits the player.
    pub async fn run(mut self, mut stream: SplitStream<Ws>, name: &str) -> Result<(), String> {
        let result = self.event_loop(&mut stream, name).await;
        let _ = self.sink.close().await;
        self.player.shutdown().await;
        result
    }

    async fn event_loop(&mut self, stream: &mut SplitStream<Ws>, name: &str) -> Result<(), String> {
        let hello = self
            .out
            .hello(self.clock.server_now(), name, self.player.source());
        self.send(hello).await?;

        let mut stdin = stdin_lines();
        let mut stdin_open = true;
        let mut poll = interval(POLL_EVERY);
        let mut report = interval(REPORT_EVERY);
        let mut clock_refresh = interval(CLOCK_EVERY);
        for i in [&mut poll, &mut report, &mut clock_refresh] {
            i.set_missed_tick_behavior(MissedTickBehavior::Delay);
        }
        let mut sigterm = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
        let mut sigint = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;

        loop {
            let nudge_end = self.nudge_until.unwrap_or_else(Instant::now);
            let step = tokio::select! {
                msg = stream.next() => self.on_ws(msg).await,
                line = stdin.recv(), if stdin_open => match line {
                    Some(line) => self.on_command(&line).await,
                    // EOF: no more commands, keep playing.
                    None => {
                        stdin_open = false;
                        Ok(Flow::Continue)
                    }
                },
                _ = poll.tick() => self.on_poll().await,
                _ = report.tick(), if self.clock.ready() => self.on_report().await,
                _ = clock_refresh.tick() => self.start_burst().await,
                _ = sleep_until(nudge_end), if self.nudge_until.is_some() => self.end_nudge().await,
                _ = sigterm.recv() => Ok(Flow::Quit),
                _ = sigint.recv() => Ok(Flow::Quit),
            };
            if let Flow::Quit = step? {
                return Ok(());
            }
        }
    }

    async fn send(&mut self, msg: String) -> Result<(), String> {
        self.sink
            .send(Message::text(msg))
            .await
            .map_err(|e| format!("websocket: {e}"))
    }

    async fn on_ws(&mut self, msg: Option<Result<Message, tungstenite::Error>>) -> Step {
        let text = match msg {
            Some(Ok(Message::Text(t))) => t.to_string(),
            Some(Ok(Message::Binary(b))) => String::from_utf8_lossy(&b).into_owned(),
            Some(Ok(Message::Close(frame))) => {
                return Err(match frame.map(|f| u16::from(f.code)) {
                    Some(4001) => "server refused the join token (4001: invalid or expired)".into(),
                    Some(4004) => "room not found (4004)".into(),
                    code => format!("server closed the connection (code {code:?})"),
                });
            }
            Some(Ok(_)) => return Ok(Flow::Continue),
            Some(Err(e)) => return Err(format!("websocket: {e}")),
            None => return Err("server closed the connection".into()),
        };
        match Inbound::parse(&text) {
            Inbound::Welcome {
                rev,
                playback,
                presence,
            } => {
                println!(
                    "joined rev={rev} members={presence} {}",
                    describe(&playback)
                );
                self.rev = rev;
                self.anchor = playback;
                if self.clock.ready() {
                    self.apply().await?;
                }
            }
            Inbound::State { rev, playback } if rev > self.rev => {
                println!("state rev={rev} {}", describe(&playback));
                self.rev = rev;
                self.anchor = playback;
                if self.clock.ready() {
                    self.apply().await?;
                }
            }
            Inbound::Pong { ping_id, t1, t2 } => self.on_pong(&ping_id, t1, t2).await?,
            Inbound::Presence { name, joined } => {
                println!("presence {} {name}", if joined { "join" } else { "leave" });
            }
            Inbound::Reject { message } => eprintln!("rejected: {message}"),
            Inbound::State { .. } | Inbound::Other => {}
        }
        Ok(Flow::Continue)
    }

    async fn on_command(&mut self, line: &str) -> Step {
        let words: Vec<&str> = line.split_whitespace().collect();
        let (op, args) = match words.as_slice() {
            [] => return Ok(Flow::Continue),
            ["q"] => return Ok(Flow::Quit),
            ["play"] => ("play", json!({ "item_ref": self.item_ref })),
            ["pause"] => ("pause", json!({})),
            ["seek", ms] => match ms.parse::<u64>() {
                Ok(ms) => ("seek", json!({ "position_ms": ms })),
                Err(_) => {
                    eprintln!("seek takes a position in ms, e.g. seek 42000");
                    return Ok(Flow::Continue);
                }
            },
            _ => {
                eprintln!("commands: play | pause | seek <ms> | q");
                return Ok(Flow::Continue);
            }
        };
        let msg = self.out.intent(self.clock.server_now(), op, args);
        self.send(msg).await?;
        Ok(Flow::Continue)
    }

    async fn start_burst(&mut self) -> Step {
        self.clock.restart_burst();
        self.send_ping().await?;
        Ok(Flow::Continue)
    }

    async fn send_ping(&mut self) -> Result<(), String> {
        let id = format!("p{}", self.pings_sent);
        self.pings_sent += 1;
        let t0 = self.clock.local_ms();
        let msg = self
            .out
            .clock_ping(self.clock.server_now(), &id, t0.floor() as i64);
        self.ping = Some((id, t0));
        self.send(msg).await
    }

    async fn on_pong(&mut self, ping_id: &str, t1: f64, t2: f64) -> Result<(), String> {
        let Some((_, t0)) = self.ping.take_if(|(id, _)| id == ping_id) else {
            return Ok(());
        };
        let t3 = self.clock.local_ms();
        let first = !self.clock.ready();
        if !self.clock.ingest(t0, t1, t2, t3) {
            return self.send_ping().await;
        }
        println!(
            "clock offset={:+.1}ms rtt={:.1}ms",
            self.clock.offset_ms(),
            self.clock.rtt_ms()
        );
        if first {
            self.apply().await?;
        }
        Ok(())
    }

    /// Makes the player follow the current anchor: load if needed, honour `paused`, and put the
    /// position right (a fresh load always seeks; otherwise the drift policy decides).
    async fn apply(&mut self) -> Result<(), String> {
        self.nudge_until = None;
        let Some(pb) = self.anchor.clone() else {
            return self.player.set_pause(true).await.map_err(player_err);
        };
        if pb.item_ref != self.item_ref && self.warned_ref.as_ref() != Some(&pb.item_ref) {
            eprintln!(
                "warning: the room plays {}, your file is {}; following the anchor anyway",
                pb.item_ref, self.item_ref
            );
            self.warned_ref = Some(pb.item_ref.clone());
        }
        self.apply_anchor(&pb).await.map_err(player_err)
    }

    async fn apply_anchor(&mut self, pb: &Playback) -> io::Result<()> {
        let fresh = self.player.ensure_loaded().await?;
        self.player.set_speed(pb.rate).await?;
        if pb.paused {
            self.player.set_pause(true).await?;
            let pos = self.player.time_pos_ms().await?;
            let off = pos.map_or(f64::INFINITY, |p| (p - pb.position_ms as f64).abs());
            if fresh || off >= DEAD_BAND_MS as f64 {
                self.player.seek_ms(pb.position_ms).await?;
            }
            return Ok(());
        }
        let pos = self.player.time_pos_ms().await?;
        let target = pb.position_at(self.clock.server_now());
        match pos.filter(|_| !fresh) {
            Some(pos) => {
                self.correct(pb, pos - target as f64).await?;
            }
            None => self.player.seek_ms(target).await?,
        }
        self.player.set_pause(false).await
    }

    /// The drift policy, for a playing anchor. Returns what it did, for the status line.
    async fn correct(&mut self, pb: &Playback, drift_ms: f64) -> io::Result<String> {
        match drift::decide(drift_ms.round() as i64) {
            Correction::None => Ok("ok".into()),
            Correction::Rate(_) if self.nudge_until.is_some() => Ok("nudging".into()),
            Correction::Rate(factor) => {
                let speed = pb.rate * factor;
                self.player.set_speed(speed).await?;
                self.nudge_until = Some(Instant::now() + NUDGE_FOR);
                Ok(format!("speed={speed:.2}"))
            }
            Correction::Seek => {
                if self.nudge_until.take().is_some() {
                    self.player.set_speed(pb.rate).await?;
                }
                let target = pb.position_at(self.clock.server_now());
                self.player.seek_ms(target).await?;
                Ok("seek".into())
            }
        }
    }

    async fn end_nudge(&mut self) -> Step {
        self.nudge_until = None;
        let rate = self.anchor.as_ref().map_or(1.0, |pb| pb.rate);
        self.player.set_speed(rate).await.map_err(player_err)?;
        Ok(Flow::Continue)
    }

    /// 1 Hz: sample `time-pos`, measure drift, correct (never while paused), print a status line.
    async fn on_poll(&mut self) -> Step {
        if let Some(reason) = self.player.exited() {
            return Err(reason);
        }
        let pos = self.player.time_pos_ms().await.map_err(player_err)?;
        let now = self.clock.server_now();
        let (Some(pb), Some(pos), true) = (self.anchor.clone(), pos, self.clock.ready()) else {
            self.drift_ms = None;
            println!("pos t={now} idle");
            return Ok(Flow::Continue);
        };
        let target = pb.position_at(now);
        let drift = pos - target as f64;
        self.drift_ms = Some(drift);
        let action = if pb.paused {
            "paused".into()
        } else {
            self.correct(&pb, drift).await.map_err(player_err)?
        };
        println!("pos t={now} pos={pos:.0} target={target} drift={drift:+.0} {action}");
        Ok(Flow::Continue)
    }

    async fn on_report(&mut self) -> Step {
        let msg = self.out.report(
            self.clock.server_now(),
            self.clock.offset_ms(),
            self.clock.rtt_ms(),
            self.drift_ms.unwrap_or(0.0),
            self.player.source(),
        );
        self.send(msg).await?;
        Ok(Flow::Continue)
    }
}

/// Stdin lines, read on a plain detached thread. `tokio::io::stdin()` would read on the blocking
/// pool, where a pending read cannot be cancelled and runtime shutdown waits for it: the process
/// would hang on exit (e.g. after a 4001 close) until the user pressed enter.
fn stdin_lines() -> mpsc::UnboundedReceiver<String> {
    let (tx, rx) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        for line in io::stdin().lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    rx
}

fn player_err(e: io::Error) -> String {
    format!("player: {e}")
}

fn describe(pb: &Option<Playback>) -> String {
    match pb {
        None => "stopped".into(),
        Some(pb) if pb.paused => format!("paused at={} item={}", pb.position_ms, pb.item_ref),
        Some(pb) => format!(
            "playing from={} anchor={} rate={} item={}",
            pb.position_ms, pb.anchor_server_ms, pb.rate, pb.item_ref
        ),
    }
}

#[cfg(test)]
mod tests {
    use wt_protocol::Playback;

    fn pb(position_ms: i64, anchor_server_ms: i64, rate: f64, paused: bool) -> Playback {
        Playback {
            item_ref: "yt:dQw4w9WgXcQ".into(),
            anchor_server_ms,
            position_ms,
            rate,
            paused,
        }
    }

    /// The target the session seeks to and measures drift against.
    #[test]
    fn anchor_math() {
        let t = 1_762_500_000_000;
        // Playing at 1x: position advances with server time.
        assert_eq!(pb(42_000, t, 1.0, false).position_at(t), 42_000);
        assert_eq!(pb(42_000, t, 1.0, false).position_at(t + 2_500), 44_500);
        // Rate scales elapsed time.
        assert_eq!(pb(10_000, t, 1.5, false).position_at(t + 2_000), 13_000);
        assert_eq!(pb(10_000, t, 0.25, false).position_at(t + 1_000), 10_250);
        // Paused: the anchor position, whatever the time.
        assert_eq!(pb(42_000, t, 1.0, true).position_at(t + 60_000), 42_000);
        assert_eq!(pb(42_000, t, 1.0, true).position_at(t - 60_000), 42_000);
        // Negative elapsed (our clock estimate is behind the anchor): extrapolate backwards...
        assert_eq!(pb(42_000, t, 1.0, false).position_at(t - 300), 41_700);
        assert_eq!(pb(42_000, t, 2.0, false).position_at(t - 300), 41_400);
        // ...but never before the start of the item.
        assert_eq!(pb(100, t, 1.0, false).position_at(t - 300), 0);
        // A later anchor replaces an earlier one; the newest anchor alone defines the target.
        let (a, b) = (pb(0, t, 1.0, false), pb(42_000, t + 5_000, 1.0, false));
        assert_eq!(a.position_at(t + 6_000), 6_000);
        assert_eq!(b.position_at(t + 6_000), 43_000);
    }
}
