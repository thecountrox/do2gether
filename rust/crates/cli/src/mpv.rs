//! A real mpv process driven over its JSON IPC socket (one JSON object per line).
//!
//! Requests are strictly sequential: write a command, read lines until the reply with the same
//! `request_id`. Events that arrive meanwhile are kept briefly so `load` can wait for
//! `file-loaded`. Socket errors are fatal to the caller; mpv command errors are logged and ignored.

use std::collections::VecDeque;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::process::{Child, Command};
use tokio::time::{Instant, sleep, timeout, timeout_at};

const CONNECT_WAIT: Duration = Duration::from_secs(5);
const REPLY_WAIT: Duration = Duration::from_secs(5);
const LOAD_WAIT: Duration = Duration::from_secs(15);
const QUIT_WAIT: Duration = Duration::from_secs(3);
const KEPT_EVENTS: usize = 32;

pub struct Mpv {
    child: Child,
    socket_path: PathBuf,
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
    next_id: u64,
    events: VecDeque<Value>,
}

impl Mpv {
    /// `mpv --idle=yes --no-terminal --input-ipc-server=<tmp>/wt-<pid>.sock`, then connects.
    pub async fn spawn(bin: &str, headless: bool) -> Result<Mpv, String> {
        let socket_path = std::env::temp_dir().join(format!("wt-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let mut cmd = Command::new(bin);
        cmd.arg("--idle=yes")
            .arg("--no-terminal")
            .arg("--hr-seek=yes")
            .arg(format!("--input-ipc-server={}", socket_path.display()));
        if headless {
            cmd.args(["--vo=null", "--ao=null"]);
        }
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .kill_on_drop(true);
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("cannot start {bin:?}: {e}"))?;

        let deadline = Instant::now() + CONNECT_WAIT;
        let stream = loop {
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!(
                    "{bin} exited before opening its IPC socket ({status})"
                ));
            }
            match UnixStream::connect(&socket_path).await {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => sleep(Duration::from_millis(50)).await,
                Err(e) => {
                    return Err(format!("cannot connect to {}: {e}", socket_path.display()));
                }
            }
        };
        let (read, writer) = stream.into_split();
        Ok(Mpv {
            child,
            socket_path,
            reader: BufReader::new(read),
            writer,
            next_id: 1,
            events: VecDeque::new(),
        })
    }

    /// Pauses, `loadfile`s and waits for `file-loaded`, so the caller can seek right after.
    pub async fn load(&mut self, path: &str) -> io::Result<()> {
        self.set_pause(true).await?;
        self.events.clear();
        self.run(json!(["loadfile", path])).await?;
        let deadline = Instant::now() + LOAD_WAIT;
        loop {
            while let Some(ev) = self.events.pop_front() {
                match ev["event"].as_str() {
                    Some("file-loaded") => return Ok(()),
                    Some("end-file") if ev["reason"] == "error" => {
                        return Err(io::Error::other(format!(
                            "mpv could not open {path}: {}",
                            ev["file_error"].as_str().unwrap_or("error")
                        )));
                    }
                    _ => {}
                }
            }
            let msg = timeout_at(deadline, self.read_message())
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "mpv: file never loaded"))??;
            self.keep_event(msg);
        }
    }

    /// True when no file is loaded (startup, or the file played to its end).
    pub async fn idle(&mut self) -> io::Result<bool> {
        let reply = self.request(json!(["get_property", "idle-active"])).await?;
        Ok(reply.ok().and_then(|v| v.as_bool()).unwrap_or(true))
    }

    pub async fn time_pos_ms(&mut self) -> io::Result<Option<f64>> {
        let reply = self.request(json!(["get_property", "time-pos"])).await?;
        Ok(reply.ok().and_then(|v| v.as_f64()).map(|s| s * 1000.0))
    }

    pub async fn seek_ms(&mut self, ms: i64) -> io::Result<()> {
        self.run(json!(["seek", ms as f64 / 1000.0, "absolute"]))
            .await
    }

    pub async fn set_pause(&mut self, paused: bool) -> io::Result<()> {
        self.run(json!(["set_property", "pause", paused])).await
    }

    pub async fn set_speed(&mut self, speed: f64) -> io::Result<()> {
        self.run(json!(["set_property", "speed", speed])).await
    }

    /// `Some(reason)` once the mpv process has exited.
    pub fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(status)) => Some(format!("mpv exited ({status})")),
            Ok(None) => None,
            Err(e) => Some(format!("mpv: {e}")),
        }
    }

    /// `quit`, wait for the process (kill it if it lingers), close the socket, remove the file.
    pub async fn quit(mut self) {
        let _ = self.writer.write_all(b"{\"command\":[\"quit\"]}\n").await;
        if timeout(QUIT_WAIT, self.child.wait()).await.is_err() {
            let _ = self.child.kill().await;
        }
        let Mpv {
            reader,
            writer,
            socket_path,
            ..
        } = self;
        drop((reader, writer));
        let _ = std::fs::remove_file(socket_path);
    }

    /// A command whose failure is worth a log line but not the session.
    async fn run(&mut self, command: Value) -> io::Result<()> {
        if let Err(e) = self.request(command.clone()).await? {
            eprintln!("mpv {command}: {e}");
        }
        Ok(())
    }

    /// Outer error: the socket is gone. Inner error: mpv's `error` string.
    async fn request(&mut self, command: Value) -> io::Result<Result<Value, String>> {
        let id = self.next_id;
        self.next_id += 1;
        let mut line = json!({ "command": command, "request_id": id }).to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await?;
        let deadline = Instant::now() + REPLY_WAIT;
        loop {
            let msg = timeout_at(deadline, self.read_message())
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "mpv did not reply"))??;
            if msg.get("event").is_some() {
                self.keep_event(msg);
            } else if msg["request_id"] == id {
                return Ok(match msg["error"].as_str() {
                    Some("success") => Ok(msg.get("data").cloned().unwrap_or(Value::Null)),
                    other => Err(other.unwrap_or("unknown error").to_owned()),
                });
            }
        }
    }

    async fn read_message(&mut self) -> io::Result<Value> {
        let mut line = String::new();
        loop {
            line.clear();
            if self.reader.read_line(&mut line).await? == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "mpv closed its IPC socket",
                ));
            }
            if let Ok(msg) = serde_json::from_str(&line) {
                return Ok(msg);
            }
        }
    }

    fn keep_event(&mut self, ev: Value) {
        if self.events.len() == KEPT_EVENTS {
            self.events.pop_front();
        }
        self.events.push_back(ev);
    }
}
