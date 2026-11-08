//! watch-together room server: HTTP routes and shared state. See `main.rs` for the binary.

pub mod clock;
mod join;
mod observability;
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
use axum::extract::{ConnectInfo, Path as UrlPath, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{get, post};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::observability::Counters;
use crate::room::Room;
use crate::store::Store;
use crate::tokens::{TOKEN_TTL_MS, sign_token_for};

pub type SharedRoom = Arc<Mutex<Room>>;

#[derive(Clone)]
pub struct AppState {
    rooms: Arc<RwLock<HashMap<String, SharedRoom>>>,
    store: Option<Arc<Store>>,
    limits: Limits,
    buckets: Arc<Mutex<HashMap<std::net::IpAddr, Bucket>>>,
    db_unavailable: bool,
    bot_token: Option<Arc<String>>,
    counters: Arc<Counters>,
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
        let counters = Arc::new(Counters::default());
        let mut rooms = HashMap::new();
        if let Some(db) = &store {
            for mut room in db.load()? {
                room.store = Some(db.clone());
                room.ttl_ms = limits.ttl_ms;
                room.max_members = limits.max_members;
                room.counters = Some(counters.clone());
                rooms.insert(room.id.clone(), Arc::new(Mutex::new(room)));
            }
        }
        Ok(Self {
            rooms: Arc::new(RwLock::new(rooms)),
            store,
            limits,
            buckets: Arc::new(Mutex::new(HashMap::new())),
            db_unavailable: false,
            bot_token: std::env::var("WT_BOT_TOKEN").ok().map(Arc::new),
            counters,
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

    /// Override bot credentials for an isolated server instance (also useful in tests).
    pub fn with_bot_token(mut self, token: Option<String>) -> Self {
        self.bot_token = token.map(Arc::new);
        self
    }

    fn bot_auth(&self, headers: &HeaderMap) -> Result<(), StatusCode> {
        let Some(expected) = &self.bot_token else {
            return Err(StatusCode::NOT_FOUND);
        };
        let Some(actual) = headers
            .get(header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Bearer "))
        else {
            return Err(StatusCode::UNAUTHORIZED);
        };
        let a = actual.as_bytes();
        let b = expected.as_bytes();
        let mut difference = a.len() ^ b.len();
        for (i, byte) in b.iter().enumerate() {
            difference |= usize::from(a.get(i).copied().unwrap_or(0) ^ byte);
        }
        if difference == 0 {
            Ok(())
        } else {
            Err(StatusCode::UNAUTHORIZED)
        }
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

    fn create_room(&self, info: CreateRoom) -> Option<(String, String)> {
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
        let host_id = info.host_id.unwrap_or_else(new_room_id);
        room.host_id = Some(host_id.clone());
        room.host_name = Some(info.host_name.unwrap_or_default());
        room.guild_id = info.guild_id;
        room.voice_channel_id = info.voice_channel_id;
        room.ttl_ms = self.limits.ttl_ms;
        room.max_members = self.limits.max_members;
        room.expires_ms = room.created_ms.saturating_add(room.ttl_ms);
        room.store = self.store.clone();
        room.degraded = self.db_unavailable;
        room.counters = Some(self.counters.clone());
        room.persist();
        rooms.insert(id.clone(), Arc::new(Mutex::new(room)));
        Some((id, host_id))
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

/// HTTP API and WebSocket entry point.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/rooms", post(create_room).fallback(not_found))
        .route("/health", get(health).fallback(not_found))
        .route(
            "/rooms/{id}",
            get(get_room)
                .patch(patch_room)
                .delete(delete_room)
                .fallback(not_found),
        )
        .route("/rooms/{id}/tokens", post(mint_token).fallback(not_found))
        .route("/join/{token}", get(join::page).fallback(not_found))
        .route("/metrics", get(metrics).fallback(not_found))
        .route("/stats", get(stats).fallback(not_found))
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
    host_id: String,
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
    let Some((room_id, host_id)) = state.create_room(info) else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "room_limit" })),
        );
    };
    let join_token = sign_token_for(&room_id, Some(&host_id));
    (
        StatusCode::CREATED,
        Json(json!(Created {
            room_id,
            join_token,
            host_id,
        })),
    )
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

fn room_meta(room: &Room) -> Value {
    json!({"room_id":room.id, "host_id":room.host_id, "host_name":room.host_name,
        "controls":room.controls, "locked":room.locked, "rev":room.rev,
        "members":room.members(), "playback":room.playback.as_ref().map(|pb| json!({
            "item_ref":pb.item_ref, "position_ms":pb.position_at(clock::server_now()),
            "paused":pb.paused })), "created_ms":room.created_ms, "expires_ms":room.expires_ms})
}

async fn get_room(State(state): State<AppState>, UrlPath(id): UrlPath<String>) -> Response {
    match state.room(&id) {
        Some(room) => {
            let room = lock(&room);
            if room.expired {
                StatusCode::NOT_FOUND.into_response()
            } else {
                Json(room_meta(&room)).into_response()
            }
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

#[derive(Deserialize)]
struct TokenRequest {
    user_id: String,
    user_name: String,
}

async fn mint_token(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    if let Err(status) = state.bot_auth(&headers) {
        return status.into_response();
    }
    let Ok(info) = serde_json::from_slice::<TokenRequest>(&body) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"invalid_body"})),
        )
            .into_response();
    };
    if info.user_id.is_empty() || info.user_name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"invalid_body"})),
        )
            .into_response();
    }
    let Some(room) = state.room(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let room = lock(&room);
    if room.expired {
        return StatusCode::NOT_FOUND.into_response();
    }
    if room.locked {
        return (StatusCode::CONFLICT, Json(json!({"error":"room_locked"}))).into_response();
    }
    if room.member_count() >= room.max_members
        && !room.members().iter().any(|m| m.user_id == info.user_id)
    {
        return (StatusCode::CONFLICT, Json(json!({"error":"room_full"}))).into_response();
    }
    Json(json!({"join_token":sign_token_for(&id, Some(&info.user_id)), "room_id":id, "expires_in_ms":TOKEN_TTL_MS}))
        .into_response()
}

#[derive(Deserialize)]
struct PatchRoom {
    locked: Option<bool>,
    controls: Option<String>,
}

async fn patch_room(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    if let Err(status) = state.bot_auth(&headers) {
        return status.into_response();
    }
    let Ok(patch) = serde_json::from_slice::<PatchRoom>(&body) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"invalid_body"})),
        )
            .into_response();
    };
    if patch
        .controls
        .as_deref()
        .is_some_and(|c| c != "host" && c != "all")
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"invalid_controls"})),
        )
            .into_response();
    }
    let Some(room) = state.room(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut room = lock(&room);
    if room.expired {
        return StatusCode::NOT_FOUND.into_response();
    }
    let changed = patch.locked.is_some_and(|locked| locked != room.locked)
        || patch
            .controls
            .as_ref()
            .is_some_and(|controls| controls != &room.controls);
    if let Some(locked) = patch.locked {
        room.locked = locked;
    }
    if let Some(controls) = patch.controls {
        room.controls = controls;
    }
    if changed {
        room.broadcast_state();
    }
    Json(room_meta(&room)).into_response()
}

async fn delete_room(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(status) = state.bot_auth(&headers) {
        return status.into_response();
    }
    let mut rooms = state.rooms.write().unwrap_or_else(PoisonError::into_inner);
    let Some(room) = rooms.remove(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut room = lock(&room);
    room.expire();
    if let Some(db) = &state.store
        && let Err(e) = db.delete(&id)
    {
        eprintln!("[db] room {id} delete failed: {e}");
        room.degraded = true;
    }
    StatusCode::NO_CONTENT.into_response()
}

async fn metrics(State(state): State<AppState>) -> Response {
    (
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        state.metrics(),
    )
        .into_response()
}

async fn stats(State(state): State<AppState>) -> Json<observability::Stats> {
    Json(state.stats())
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}
