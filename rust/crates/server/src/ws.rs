//! `GET /ws?room=&token=`: authenticate, then pump one connection through its room.

use std::time::Duration;

use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use tokio::sync::mpsc;

use crate::clock::server_now;
use crate::tokens::verify_token;
use crate::{AppState, SharedRoom, lock};

const MAX_PAYLOAD_BYTES: usize = 64 * 1024;
const CLOSE_INVALID_TOKEN: (u16, &str) = (4001, "invalid token");
const CLOSE_ROOM_NOT_FOUND: (u16, &str) = (4004, "room not found");
/// How long a refused socket waits for the client's close reply.
const CLOSE_GRACE: Duration = Duration::from_secs(5);

pub(crate) async fn upgrade(
    State(state): State<AppState>,
    Query(params): Query<Vec<(String, String)>>,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Ok(upgrade) = upgrade else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // First occurrence wins, like URLSearchParams.get.
    let param = |name: &str| {
        params
            .iter()
            .find(|(k, _)| k == name)
            .map_or("", |(_, v)| v.as_str())
    };
    let room_id = param("room");
    let target = if verify_token(param("token"), room_id) {
        state.room(room_id).ok_or(CLOSE_ROOM_NOT_FOUND)
    } else {
        Err(CLOSE_INVALID_TOKEN)
    };
    upgrade
        .max_message_size(MAX_PAYLOAD_BYTES)
        .max_frame_size(MAX_PAYLOAD_BYTES)
        .on_upgrade(move |socket| async move {
            match target {
                Ok(room) => run(socket, room).await,
                Err((code, reason)) => refuse(socket, code, reason).await,
            }
        })
}

async fn refuse(mut socket: WebSocket, code: u16, reason: &'static str) {
    let frame = CloseFrame {
        code,
        reason: reason.into(),
    };
    if socket.send(Message::Close(Some(frame))).await.is_ok() {
        let drain = async { while socket.recv().await.is_some() {} };
        let _ = tokio::time::timeout(CLOSE_GRACE, drain).await;
    }
}

async fn run(mut socket: WebSocket, room: SharedRoom) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let conn = lock(&room).attach(tx);
    loop {
        tokio::select! {
            incoming = socket.recv() => {
                let received_at = server_now();
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        lock(&room).handle_message(conn, text.as_str(), received_at);
                    }
                    Some(Ok(Message::Binary(bytes))) => {
                        let text = String::from_utf8_lossy(&bytes);
                        lock(&room).handle_message(conn, &text, received_at);
                    }
                    // Pings are answered by tungstenite; a close is answered on the next recv,
                    // which then yields None.
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Close(_))) => {}
                    Some(Err(e)) => {
                        eprintln!("[ws] {e}");
                        break;
                    }
                    None => break,
                }
            }
            Some(data) = rx.recv() => {
                if socket.send(Message::Text(data.into())).await.is_err() {
                    break;
                }
            }
        }
    }
    lock(&room).detach(conn);
}
