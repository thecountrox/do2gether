//! watch-together room server: HTTP routes and shared state. See `main.rs` for the binary.

pub mod clock;
pub mod room;
pub mod store;
pub mod tokens;
mod ws;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::{ConnectInfo, State};
use axum::http::StatusCode;
use axum::response::Json;
use axum::routing::{get, post};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::room::Room;
use crate::store::Store;
use crate::tokens::sign_token;

pub type SharedRoom = Arc<Mutex<Room>>;

#[derive(Clone)]
pub struct AppState {
    rooms: Arc<RwLock<HashMap<String, SharedRoom>>>,
    store: Option<Arc<Store>>,
    limits: Limits,
    buckets: Arc<Mutex<HashMap<std::net::IpAddr, Bucket>>>,
    db_unavailable: bool,
}

#[derive(Clone)]
pub struct Limits {
    pub max_rooms: usize,
    pub max_members: usize,
    pub ttl_ms: i64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_rooms: 500,
            max_members: 50,
            ttl_ms: 24 * 60 * 60 * 1000,
        }
    }
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

impl Default for AppState {
    fn default() -> Self {
        Self::with_limits(None, Limits::default()).expect("in-memory state")
    }
}

impl AppState {
    pub fn open(path: &Path, limits: Limits) -> rusqlite::Result<Self> {
        Self::with_limits(Some(path), limits)
    }

    fn with_limits(path: Option<&Path>, limits: Limits) -> rusqlite::Result<Self> {
        let store = path.map(Store::open).transpose()?.map(Arc::new);
        let mut rooms = HashMap::new();
        if let Some(db) = &store {
            for mut room in db.load()? {
                room.store = Some(db.clone());
                room.ttl_ms = limits.ttl_ms;
                room.max_members = limits.max_members;
                rooms.insert(room.id.clone(), Arc::new(Mutex::new(room)));
            }
        }
        Ok(Self {
            rooms: Arc::new(RwLock::new(rooms)),
            store,
            limits,
            buckets: Arc::new(Mutex::new(HashMap::new())),
            db_unavailable: false,
        })
    }

    /// If opening the DB fails, continue in degraded memory-only mode.
    pub fn open_or_degraded(path: &Path, limits: Limits) -> Self {
        match Self::open(path, limits.clone()) {
            Ok(state) => state,
            Err(e) => {
                eprintln!("[db] open failed for {}: {e}", path.display());
                let mut state = Self::with_limits(None, limits).expect("in-memory state");
                state.db_unavailable = true;
                state
            }
        }
    }

    pub fn room(&self, id: &str) -> Option<SharedRoom> {
        self.rooms
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()
    }

    pub fn sweep(&self, now: i64) {
        let mut rooms = self.rooms.write().unwrap_or_else(PoisonError::into_inner);
        rooms.retain(|id, room| {
            let mut room = lock(room);
            if room.expires_ms >= now {
                return true;
            }
            room.expire();
            if let Some(db) = &self.store
                && let Err(e) = db.delete(id)
            {
                eprintln!("[db] room {id} expiry delete failed: {e}");
                room.degraded = true;
            }
            false
        });
    }

    fn allow_ip(&self, ip: std::net::IpAddr) -> bool {
        let mut buckets = lock(&self.buckets);
        let now = Instant::now();
        buckets.retain(|_, b| now.duration_since(b.last) < Duration::from_secs(60));
        let bucket = buckets.entry(ip).or_insert(Bucket {
            tokens: 5.0,
            last: now,
        });
        bucket.tokens =
            (bucket.tokens + now.duration_since(bucket.last).as_secs_f64() * 5.0 / 60.0).min(5.0);
        bucket.last = now;
        if bucket.tokens < 1.0 {
            return false;
        }
        bucket.tokens -= 1.0;
        true
    }

    fn create_room(&self, info: CreateRoom) -> Option<String> {
        let mut rooms = self.rooms.write().unwrap_or_else(PoisonError::into_inner);
        if rooms.len() >= self.limits.max_rooms {
            return None;
        }
        let id = loop {
            let id = new_room_id();
            if !rooms.contains_key(&id)
                && !self
                    .store
                    .as_ref()
                    .is_some_and(|db| db.exists(&id).unwrap_or(false))
            {
                break id;
            }
        };
        let mut room = Room::new(id.clone());
        room.host_id = info.host_id;
        room.host_name = info.host_name;
        room.guild_id = info.guild_id;
        room.voice_channel_id = info.voice_channel_id;
        room.ttl_ms = self.limits.ttl_ms;
        room.max_members = self.limits.max_members;
        room.expires_ms = room.created_ms.saturating_add(room.ttl_ms);
        room.store = self.store.clone();
        room.degraded = self.db_unavailable;
        room.persist();
        rooms.insert(id.clone(), Arc::new(Mutex::new(room)));
        Some(id)
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

#[derive(Default, Deserialize)]
struct CreateRoom {
    host_id: Option<String>,
    host_name: Option<String>,
    guild_id: Option<String>,
    voice_channel_id: Option<String>,
}

#[derive(Serialize)]
struct Created {
    room_id: String,
    join_token: String,
}

async fn create_room(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    body: axum::body::Bytes,
) -> (StatusCode, Json<Value>) {
    let info = if body.is_empty() {
        CreateRoom::default()
    } else {
        match serde_json::from_slice(&body) {
            Ok(info) => info,
            Err(_) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "invalid_body" })),
                );
            }
        }
    };
    if !state.allow_ip(addr.ip()) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({ "error": "rate_limited" })),
        );
    }
    let Some(room_id) = state.create_room(info) else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "room_limit" })),
        );
    };
    let join_token = sign_token(&room_id);
    (
        StatusCode::CREATED,
        Json(json!(Created {
            room_id,
            join_token,
        })),
    )
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}
