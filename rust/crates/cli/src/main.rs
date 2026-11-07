//! `wt-play`: join a room and keep an mpv player (or a simulated one) on the room's anchor.

mod args;
mod clock;
mod drift;
mod media;
mod mpv;
mod net;
mod player;
mod session;
mod wire;

/// The server's test harness, for its schema validator.
#[cfg(test)]
#[allow(dead_code)]
#[path = "../../server/tests/support/mod.rs"]
mod support;

use std::path::Path;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::StreamExt;

use crate::args::{Args, Join, USAGE};
use crate::clock::Clock;
use crate::mpv::Mpv;
use crate::net::ServerUrl;
use crate::player::{Player, Sim};
use crate::session::Session;
use crate::wire::Outbox;

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let args = match args::parse(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("wt-play: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(args).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("wt-play: {e}");
            ExitCode::FAILURE
        }
    }
}

async fn run(args: Args) -> Result<(), String> {
    let server = ServerUrl::parse(&args.server)?;
    let (file, item_ref) = match &args.file {
        Some(path) => {
            let (file, item_ref) = open_media(path)?;
            (Some(file), item_ref)
        }
        None => (None, media::empty_item_ref()),
    };

    let (room, token) = match args.join {
        Join::Create => {
            let (room, token) = server.create_room().await?;
            println!("room: {room}");
            println!(
                "share: wt-play --server {} --room {room} --token {token} --file <path>",
                args.server
            );
            (room, token)
        }
        Join::Room { id, token } => (id, token),
    };

    let player = match file {
        Some(file) if !args.simulate => Player::Mpv {
            mpv: Box::new(Mpv::spawn(&args.mpv, args.headless).await?),
            file,
        },
        _ => Player::Sim(Sim::default()),
    };
    let ws = match server.connect_ws(&room, &token).await {
        Ok(ws) => ws,
        Err(e) => {
            player.shutdown().await;
            return Err(format!("cannot connect to {}: {e}", args.server));
        }
    };
    let (sink, stream) = ws.split();

    let user_id = user_id();
    println!("user: {user_id} name: {}", args.name);
    let out = Outbox::new(&room, &user_id);
    let session = Session::new(sink, out, Clock::new(), player, item_ref);
    session.run(stream, &args.name).await
}

/// Absolute UTF-8 path (mpv gets it as a JSON string) and the file's `item_ref`.
fn open_media(path: &Path) -> Result<(String, String), String> {
    let abs = std::fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let file = abs
        .to_str()
        .ok_or_else(|| format!("{}: path is not UTF-8", abs.display()))?
        .to_owned();
    let item_ref = media::item_ref(&abs).map_err(|e| format!("{file}: {e}"))?;
    Ok((file, item_ref))
}

/// Unique per process, so two players on one machine are two members.
fn user_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    format!("wt-{}-{nanos:x}", std::process::id())
}
