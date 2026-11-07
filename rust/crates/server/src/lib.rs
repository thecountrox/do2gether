//! watch-together room server: HTTP routes and shared state. See `main.rs` for the binary.

pub mod clock;
pub mod room;
pub mod tokens;
mod ws;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::Json;
use axum::routing::{get, post};
use rand::Rng;
use serde::Serialize;
use serde_json::{Value, json};

use crate::room::Room;
use crate::tokens::sign_token;

pub type SharedRoom = Arc<Mutex<Room>>;

/// All rooms, in memory. Rooms live until the process exits.
#[derive(Clone, Default)]
pub struct AppState {
    rooms: Arc<Mutex<HashMap<String, SharedRoom>>>,
}

impl AppState {
    pub fn room(&self, id: &str) -> Option<SharedRoom> {
        lock(&self.rooms).get(id).cloned()
    }

    fn create_room(&self) -> String {
        let mut rooms = lock(&self.rooms);
        let id = loop {
            let id = new_room_id();
            if !rooms.contains_key(&id) {
                break id;
            }
        };
        rooms.insert(id.clone(), Arc::new(Mutex::new(Room::new(id.clone()))));
        id
    }
}

/// A panic while holding a lock must not take the whole room (or server) down with it.
pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn new_room_id() -> String {
    const BASE36: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut rng = rand::rng();
    (0..8)
        .map(|_| char::from(BASE36[rng.random_range(0..BASE36.len())]))
        .collect()
}

/// `POST /rooms`, `GET /health`, `GET /ws`; everything else (wrong method included) is 404.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/rooms", post(create_room).fallback(not_found))
        .route("/health", get(health).fallback(not_found))
        .route("/ws", get(ws::upgrade).fallback(not_found))
        .fallback(not_found)
        .with_state(state)
}

#[derive(Serialize)]
struct Created {
    room_id: String,
    join_token: String,
}

async fn create_room(State(state): State<AppState>) -> (StatusCode, Json<Created>) {
    let room_id = state.create_room();
    let join_token = sign_token(&room_id);
    (
        StatusCode::CREATED,
        Json(Created {
            room_id,
            join_token,
        }),
    )
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}
