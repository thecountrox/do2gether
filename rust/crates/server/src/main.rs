use std::io;

use std::path::Path;
use std::time::Duration;
use tokio::net::TcpListener;
use wt_server::Limits;
use wt_server::{AppState, router};

#[tokio::main]
async fn main() -> io::Result<()> {
    let port = match std::env::var("PORT") {
        Ok(p) => p
            .parse::<u16>()
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, format!("PORT={p:?}: {e}")))?,
        Err(_) => 8787,
    };
    let host = std::env::var("BIND").unwrap_or_else(|_| "0.0.0.0".to_string());
    let listener = TcpListener::bind((host.as_str(), port)).await?;
    println!(
        "watch-together server listening on :{}",
        listener.local_addr()?.port()
    );
    let mut limits = Limits::default();
    for (key, target) in [
        ("WT_MAX_ROOMS", &mut limits.max_rooms),
        ("WT_MAX_MEMBERS", &mut limits.max_members),
    ] {
        if let Ok(value) = std::env::var(key) {
            *target = value
                .parse()
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, format!("{key}: {e}")))?;
        }
    }
    if let Ok(value) = std::env::var("WT_ROOM_TTL_HOURS") {
        let hours: i64 = value.parse().map_err(|e| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("WT_ROOM_TTL_HOURS: {e}"),
            )
        })?;
        limits.ttl_ms = hours.checked_mul(3_600_000).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WT_ROOM_TTL_HOURS overflow")
        })?;
    }
    let db = std::env::var("WT_DB").unwrap_or_else(|_| "wt.db".into());
    let state = AppState::open_or_degraded(Path::new(&db), limits);
    let sweep_state = state.clone();
    tokio::spawn(async move {
        let mut timer = tokio::time::interval(Duration::from_secs(60));
        timer.tick().await;
        loop {
            timer.tick().await;
            sweep_state.sweep(wt_server::clock::server_now());
        }
    });
    axum::serve(
        listener,
        router(state).into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
}
