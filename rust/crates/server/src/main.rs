use std::io;

use tokio::net::TcpListener;
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
    axum::serve(listener, router(AppState::default())).await
}
