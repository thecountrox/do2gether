//! `wt-play --simulate` end to end against an in-process server on port 0. No mpv needed.
//! `live_tls_roundtrip` (ignored by default) targets the deployed server instead.

#[allow(dead_code)]
#[path = "../../server/tests/support/mod.rs"]
mod support;

use std::process::{ExitStatus, Stdio};
use std::time::Duration;

use support::{RoomInfo, Server, presence_ids};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tokio::time::{Instant, sleep, timeout, timeout_at};
use wt_protocol::Playback;
use wt_server::tokens::verify_token;

const WAIT: Duration = Duration::from_secs(5);
/// Well inside the server's 5 s close grace, so exiting only once the server drops a refused
/// socket does not count as prompt.
const PROMPT: Duration = Duration::from_secs(2);
const TOLERANCE_MS: f64 = 100.0;

struct WtPlay {
    name: String,
    child: Child,
    stdin: ChildStdin,
    lines: mpsc::UnboundedReceiver<String>,
    errors: mpsc::UnboundedReceiver<String>,
}

impl WtPlay {
    fn spawn(name: &str, args: &[&str]) -> WtPlay {
        let mut child = Command::new(env!("CARGO_BIN_EXE_wt-play"))
            .args(args)
            .args(["--name", name])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .expect("wt-play starts");
        let lines = read_lines(child.stdout.take().unwrap(), false);
        let errors = read_lines(child.stderr.take().unwrap(), true);
        let stdin = child.stdin.take().unwrap();
        WtPlay {
            name: name.to_owned(),
            child,
            stdin,
            lines,
            errors,
        }
    }

    fn join(server: &Server, room: &RoomInfo, name: &str) -> WtPlay {
        let url = format!("http://{}", server.addr);
        let args = [
            "--server",
            &url,
            "--room",
            &room.room_id,
            "--token",
            &room.join_token,
        ];
        WtPlay::spawn(name, &[&args[..], &["--simulate"]].concat())
    }

    /// The next stdout line matching `pred`; earlier lines are dropped.
    async fn line(&mut self, what: &str, pred: impl Fn(&str) -> bool) -> String {
        let deadline = Instant::now() + WAIT;
        loop {
            match timeout_at(deadline, self.lines.recv()).await {
                Ok(Some(line)) if pred(&line) => return line,
                Ok(Some(_)) => {}
                Ok(None) => panic!("{}: exited while waiting for {what}", self.name),
                Err(_) => panic!("{}: no {what} within {WAIT:?}", self.name),
            }
        }
    }

    /// The first status line sampled at or after server time `t`.
    async fn pos_at_or_after(&mut self, t: i64) -> Pos {
        let line = self
            .line("status line", |l| parse_pos(l).is_some_and(|p| p.t >= t))
            .await;
        parse_pos(&line).unwrap()
    }

    async fn cmd(&mut self, cmd: &str) {
        self.stdin
            .write_all(format!("{cmd}\n").as_bytes())
            .await
            .unwrap();
    }

    async fn quit(mut self) -> ExitStatus {
        self.cmd("q").await;
        timeout(WAIT, self.child.wait())
            .await
            .expect("wt-play exits after q")
            .unwrap()
    }
}

/// A child pipe's lines as a channel, closed at EOF. `echo` also copies them to the test output.
fn read_lines(
    pipe: impl AsyncRead + Unpin + Send + 'static,
    echo: bool,
) -> mpsc::UnboundedReceiver<String> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut pipe = BufReader::new(pipe).lines();
        while let Ok(Some(line)) = pipe.next_line().await {
            if echo {
                eprintln!("{line}");
            }
            let _ = tx.send(line);
        }
    });
    rx
}

#[derive(Debug, Clone, Copy)]
struct Pos {
    t: i64,
    pos: f64,
}

/// `pos t=<server ms> pos=<ms> target=... drift=... <action>`
fn parse_pos(line: &str) -> Option<Pos> {
    let mut fields = line.strip_prefix("pos ")?.split(' ');
    let t = fields.next()?.strip_prefix("t=")?.parse().ok()?;
    let pos = fields.next()?.strip_prefix("pos=")?.parse().ok()?;
    Some(Pos { t, pos })
}

fn word_after<'a>(line: &'a str, flag: &str) -> &'a str {
    let mut words = line.split_whitespace();
    words.find(|w| *w == flag);
    words
        .next()
        .unwrap_or_else(|| panic!("no {flag} in {line:?}"))
}

async fn wait_for_playback(
    server: &Server,
    room: &str,
    pred: impl Fn(&Playback) -> bool,
) -> Playback {
    let room = server.room(room);
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(pb) = room.lock().unwrap().playback.clone().filter(&pred) {
            return pb;
        }
        assert!(
            Instant::now() < deadline,
            "room never reached the expected playback"
        );
        sleep(Duration::from_millis(10)).await;
    }
}

/// Both players sampled at least `after`: each within tolerance of the anchor, and of each other
/// when one is extrapolated to the other's sample time.
async fn assert_converged(a: &mut WtPlay, b: &mut WtPlay, pb: &Playback, after: i64) -> (Pos, Pos) {
    let (pa, pbb) = (
        a.pos_at_or_after(after).await,
        b.pos_at_or_after(after).await,
    );
    for (name, p) in [("a", pa), ("b", pbb)] {
        let expected = pb.position_at(p.t) as f64;
        assert!(
            (p.pos - expected).abs() <= TOLERANCE_MS,
            "{name} at t={} is at {} ms, anchor says {expected}",
            p.t,
            p.pos
        );
    }
    let a_at_b = pa.pos + (pbb.t - pa.t) as f64 * pb.rate;
    assert!(
        (a_at_b - pbb.pos).abs() <= TOLERANCE_MS,
        "a {pa:?} and b {pbb:?} differ by {} ms",
        a_at_b - pbb.pos
    );
    (pa, pbb)
}

#[tokio::test]
async fn two_simulated_clients_converge_after_play_and_seek() {
    let server = Server::start().await;
    let room = server.create_room().await;
    server.room(&room.room_id).lock().unwrap().controls = "all".into();
    let mut a = WtPlay::join(&server, &room, "ann");
    let mut b = WtPlay::join(&server, &room, "bob");
    let mut users = Vec::new();
    for c in [&mut a, &mut b] {
        let user = c.line("user line", |l| l.starts_with("user: ")).await;
        users.push(word_after(&user, "user:").to_owned());
        c.line("clock burst", |l| l.starts_with("clock ")).await;
    }

    a.cmd("play").await;
    let played = wait_for_playback(&server, &room.room_id, |pb| !pb.paused).await;
    sleep(Duration::from_secs(2)).await;
    assert_converged(&mut a, &mut b, &played, played.anchor_server_ms + 2000).await;

    b.cmd("seek 42000").await;
    let seeked = wait_for_playback(&server, &room.room_id, |pb| pb.position_ms == 42_000).await;
    sleep(Duration::from_secs(2)).await;
    let (pa, pbb) = assert_converged(&mut a, &mut b, &seeked, seeked.anchor_server_ms + 2000).await;
    assert!(pa.pos >= 44_000.0 - TOLERANCE_MS && pbb.pos >= 44_000.0 - TOLERANCE_MS);

    // Both reported (the first report goes out as soon as the clock is ready).
    for user in &users {
        let room = server.room(&room.room_id);
        let report = room.lock().unwrap().report_for(user).cloned();
        let report = report.unwrap_or_else(|| panic!("no report from {user}"));
        assert_eq!(report.activity_id, None);
        assert_eq!(report.observed.source, "simulate");
    }

    assert!(a.quit().await.success());
    assert!(b.quit().await.success());
    server.wait_for_clients(&room.room_id, 0).await;
}

#[tokio::test]
async fn create_prints_a_joinable_room() {
    let server = Server::start().await;
    let url = format!("http://{}", server.addr);
    let mut host = WtPlay::spawn("host", &["--server", &url, "--create", "--simulate"]);
    let room_line = host.line("room line", |l| l.starts_with("room: ")).await;
    let share = host.line("share line", |l| l.starts_with("share: ")).await;
    let room_id = word_after(&room_line, "room:").to_owned();
    assert_eq!(word_after(&share, "--room"), room_id);
    assert_eq!(word_after(&share, "--server"), url);
    let token = word_after(&share, "--token").to_owned();
    assert!(
        verify_token(&token, &room_id),
        "share line carries a valid token"
    );
    assert!(
        server.state.room(&room_id).is_some(),
        "room exists server-side"
    );

    let host_user = host.line("user line", |l| l.starts_with("user: ")).await;
    let host_user = word_after(&host_user, "user:").to_owned();
    host.line("welcome", |l| l.starts_with("joined ")).await;

    // Joinable with exactly what was printed: a protocol client gets in and sees the host.
    let info = RoomInfo {
        room_id,
        join_token: token,
        host_id: host_user.clone(),
    };
    let (probe, welcome) = server.join("probe", &info).await;
    let mut expected = vec![host_user, "probe".to_owned()];
    expected.sort();
    assert_eq!(presence_ids(&welcome), expected);
    probe.close().await;
    assert!(host.quit().await.success());
}

/// The deployed server over https/wss (Caddy in front). Run manually:
/// `cargo test -p wt-cli --test sim -- --ignored live_tls_roundtrip`.
#[tokio::test]
#[ignore = "needs the network and the deployed server"]
async fn live_tls_roundtrip() {
    let url = "https://watch.141.253.97.15.sslip.io";
    let mut host = WtPlay::spawn("tls-test", &["--server", url, "--create", "--simulate"]);
    host.line("room line", |l| l.starts_with("room: ")).await;
    host.line("welcome", |l| l.starts_with("joined ")).await;
    host.cmd("play").await;
    host.line("playing state", |l| {
        l.starts_with("state ") && l.contains(" playing ")
    })
    .await;
    assert!(host.quit().await.success());
}

#[tokio::test]
async fn refused_token_exits_with_an_error() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let bad = RoomInfo {
        room_id: room.room_id.clone(),
        join_token: "nope.nope".into(),
        host_id: room.host_id.clone(),
    };
    let mut c = WtPlay::join(&server, &bad, "eve");
    // `c.stdin` stays open, as on a terminal: the 4001 close alone has to end the process.
    let status = timeout(PROMPT, c.child.wait())
        .await
        .expect("wt-play exits promptly on a 4001 close, stdin still open")
        .unwrap();
    assert_eq!(status.code(), Some(1));

    // And it exited because of the refusal, not some other error.
    let mut stderr = Vec::new();
    while let Some(line) = timeout(WAIT, c.errors.recv()).await.expect("stderr closes") {
        stderr.push(line);
    }
    assert!(
        stderr
            .iter()
            .any(|l| l.contains("refused the join token (4001")),
        "stderr names the 4001 refusal: {stderr:?}"
    );
}
