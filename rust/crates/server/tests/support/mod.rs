//! Test harness: a real server on port 0 per test, real WebSocket clients, and a minimal JSON
//! Schema validator for `protocol/room.schema.json` that every message in either direction must
//! pass. Port of the harness in `server/test/room.test.ts`.

use std::net::SocketAddr;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::header::{CONTENT_TYPE, HOST};
use hyper::{Method, Request, StatusCode};
use hyper_util::rt::TokioIo;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, timeout, timeout_at};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use wt_protocol::{ITEM_REF_PATTERN, is_item_ref};
use wt_server::{AppState, SharedRoom, router};

pub const FILM: &str =
    "file:sha256p:1073741824:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
pub const SONG: &str = "subsonic:navidrome/tr-0001";
pub const CLIP: &str = "yt:dQw4w9WgXcQ";

const DEFAULT_WAIT: Duration = Duration::from_millis(1000);

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

pub fn int(v: &Value) -> i64 {
    v.as_i64()
        .unwrap_or_else(|| panic!("expected an integer, got {v}"))
}

/// `paused ? position_ms : position_ms + (now - anchor_server_ms) * rate`, as the TS test computes it.
pub fn position_at(pb: &Value, now: i64) -> f64 {
    let position = int(&pb["position_ms"]) as f64;
    if pb["paused"] == true {
        return position;
    }
    position + (now - int(&pb["anchor_server_ms"])) as f64 * pb["rate"].as_f64().unwrap()
}

pub fn presence_ids(welcome: &Value) -> Vec<String> {
    let mut ids: Vec<String> = welcome["snapshot"]["presence"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["user_id"].as_str().unwrap().to_owned())
        .collect();
    ids.sort();
    ids
}

pub fn assert_strictly_increasing(xs: &[i64], label: &str) {
    assert!(
        xs.windows(2).all(|w| w[0] < w[1]),
        "{label} not strictly increasing: {xs:?}"
    );
}

// ---------------------------------------------------------------------------
// Minimal JSON Schema validator. Supports exactly the keywords the schema uses and panics on
// anything else, so a schema change can never be silently ignored. There is no regex engine in
// the dependency tree: the one `pattern` in the schema must equal `wt_protocol::ITEM_REF_PATTERN`
// and is checked with `is_item_ref` (whose own tests cover the pattern case by case).
// ---------------------------------------------------------------------------

pub static SCHEMA: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../../../../protocol/room.schema.json"))
        .expect("room.schema.json is JSON")
});

const ANNOTATIONS: [&str; 7] = [
    "$schema",
    "$id",
    "title",
    "description",
    "$defs",
    "then",
    "else",
];

pub fn validate_message(v: &Value) -> Vec<String> {
    errors_of(&SCHEMA, v, "$")
}

fn errors_of(schema: &Value, v: &Value, path: &str) -> Vec<String> {
    let mut errs = Vec::new();
    validate(schema, v, path, &mut errs);
    errs
}

fn type_matches(t: &str, v: &Value) -> bool {
    match t {
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        // Number.isInteger semantics: 3.0 is an integer.
        "integer" => v.is_i64() || v.is_u64() || v.as_f64().is_some_and(|f| f.fract() == 0.0),
        "number" => v.is_number(),
        "boolean" => v.is_boolean(),
        "null" => v.is_null(),
        other => panic!("validator: unsupported type {other}"),
    }
}

/// JSON equality with numbers compared by value (1 == 1.0), as in JS.
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a.as_f64(), b.as_f64()) {
        (Some(x), Some(y)) => x == y,
        _ => a == b,
    }
}

fn validate(schema: &Value, v: &Value, path: &str, errs: &mut Vec<String>) {
    let schema = schema
        .as_object()
        .expect("validator: schema nodes are objects");
    for (kw, arg) in schema {
        match kw.as_str() {
            "$ref" => {
                let target = arg
                    .as_str()
                    .and_then(|r| r.strip_prefix("#/$defs/"))
                    .and_then(|name| SCHEMA["$defs"].get(name))
                    .unwrap_or_else(|| panic!("validator: unresolved $ref {arg}"));
                validate(target, v, path, errs);
            }
            "type" => {
                let types: Vec<&str> = match arg {
                    Value::Array(ts) => ts.iter().map(|t| t.as_str().unwrap()).collect(),
                    t => vec![t.as_str().unwrap()],
                };
                if !types.iter().any(|t| type_matches(t, v)) {
                    errs.push(format!("{path}: expected {}", types.join("|")));
                }
            }
            "const" => {
                if !json_eq(v, arg) {
                    errs.push(format!("{path}: expected {arg}"));
                }
            }
            "enum" => {
                if !arg.as_array().unwrap().iter().any(|e| json_eq(v, e)) {
                    errs.push(format!("{path}: {v} not in enum"));
                }
            }
            "required" => {
                if let Some(o) = v.as_object() {
                    for k in arg.as_array().unwrap().iter().map(|k| k.as_str().unwrap()) {
                        if !o.contains_key(k) {
                            errs.push(format!("{path}.{k}: required"));
                        }
                    }
                }
            }
            "properties" => {
                if let Some(o) = v.as_object() {
                    for (k, sub) in arg.as_object().unwrap() {
                        if let Some(x) = o.get(k) {
                            validate(sub, x, &format!("{path}.{k}"), errs);
                        }
                    }
                }
            }
            "items" => {
                if let Some(xs) = v.as_array() {
                    for (i, x) in xs.iter().enumerate() {
                        validate(arg, x, &format!("{path}[{i}]"), errs);
                    }
                }
            }
            "allOf" => {
                for sub in arg.as_array().unwrap() {
                    validate(sub, v, path, errs);
                }
            }
            "anyOf" => {
                let any = arg.as_array().unwrap();
                if !any.iter().any(|sub| errors_of(sub, v, path).is_empty()) {
                    errs.push(format!("{path}: matches no anyOf branch"));
                }
            }
            "if" => {
                let branch = if errors_of(arg, v, path).is_empty() {
                    schema.get("then")
                } else {
                    schema.get("else")
                };
                if let Some(branch) = branch {
                    validate(branch, v, path, errs);
                }
            }
            "pattern" => {
                assert_eq!(arg, ITEM_REF_PATTERN, "validator: unsupported pattern");
                if let Some(s) = v.as_str()
                    && !is_item_ref(s)
                {
                    errs.push(format!("{path}: does not match pattern"));
                }
            }
            "minimum" => {
                if let Some(x) = v.as_f64()
                    && x < arg.as_f64().unwrap()
                {
                    errs.push(format!("{path}: below minimum {arg}"));
                }
            }
            "maximum" => {
                if let Some(x) = v.as_f64()
                    && x > arg.as_f64().unwrap()
                {
                    errs.push(format!("{path}: above maximum {arg}"));
                }
            }
            "minLength" => {
                if let Some(s) = v.as_str()
                    && (s.chars().count() as u64) < arg.as_u64().unwrap()
                {
                    errs.push(format!("{path}: shorter than {arg}"));
                }
            }
            "maxLength" => {
                if let Some(s) = v.as_str()
                    && (s.chars().count() as u64) > arg.as_u64().unwrap()
                {
                    errs.push(format!("{path}: longer than {arg}"));
                }
            }
            kw if ANNOTATIONS.contains(&kw) => {}
            other => panic!("validator: unsupported keyword {other}"),
        }
    }
}

// ---------------------------------------------------------------------------
// Server + clients
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct RoomInfo {
    pub room_id: String,
    pub join_token: String,
    pub host_id: String,
}

/// One server per test. On drop (unless the test already failed) asserts that every message the
/// clients received validated against the schema.
pub struct Server {
    pub addr: SocketAddr,
    pub state: AppState,
    schema_errors: Arc<Mutex<Vec<String>>>,
}

impl Drop for Server {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let errs = self.schema_errors.lock().unwrap();
            assert!(
                errs.is_empty(),
                "every server message must validate against room.schema.json: {errs:#?}"
            );
        }
    }
}

/// encodeURIComponent
fn encode_component(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

impl Server {
    pub async fn start() -> Server {
        Self::start_with_state(AppState::default()).await
    }

    pub async fn start_with_state(state: AppState) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = router(state.clone());
        tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .unwrap()
        });
        Server {
            addr,
            state,
            schema_errors: Arc::default(),
        }
    }

    pub fn room(&self, id: &str) -> SharedRoom {
        self.state.room(id).expect("room exists server-side")
    }

    /// Polls until the room has exactly `n` attached connections (detach runs after the close
    /// handshake, so a client's `close()` can return a moment before the server has detached it).
    pub async fn wait_for_clients(&self, room_id: &str, n: usize) {
        let room = self.room(room_id);
        let deadline = Instant::now() + DEFAULT_WAIT;
        while room.lock().unwrap().client_count() != n {
            assert!(Instant::now() < deadline, "room never reached {n} clients");
            sleep(Duration::from_millis(5)).await;
        }
    }

    /// Returns status, content-type and body.
    pub async fn http(&self, method: Method, path: &str) -> (StatusCode, Option<String>, Bytes) {
        self.http_body(method, path, Bytes::new()).await
    }

    pub async fn http_body(
        &self,
        method: Method,
        path: &str,
        request_body: Bytes,
    ) -> (StatusCode, Option<String>, Bytes) {
        let stream = TcpStream::connect(self.addr).await.unwrap();
        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
            .await
            .unwrap();
        tokio::spawn(conn);
        let req = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, self.addr.to_string())
            .body(Full::new(request_body))
            .unwrap();
        let res = sender.send_request(req).await.unwrap();
        let status = res.status();
        let content_type = res
            .headers()
            .get(CONTENT_TYPE)
            .map(|v| v.to_str().unwrap().to_owned());
        let body = res.into_body().collect().await.unwrap().to_bytes();
        (status, content_type, body)
    }

    pub async fn create_room(&self) -> RoomInfo {
        let (status, _, body) = self
            .http_body(
                Method::POST,
                "/rooms",
                json!({"host_id":"alice", "host_name":"alice"})
                    .to_string()
                    .into(),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
        serde_json::from_slice(&body).unwrap()
    }

    pub fn ws_url(&self, room_id: &str, token: &str) -> String {
        format!(
            "ws://{}/ws?room={}&token={}",
            self.addr,
            encode_component(room_id),
            encode_component(token)
        )
    }

    pub async fn connect(&self, id: &str, room: &RoomInfo) -> Client {
        let (ws, _) = connect_async(self.ws_url(&room.room_id, &room.join_token))
            .await
            .unwrap();
        let (sink, mut stream) = ws.split();
        let (tx, rx) = mpsc::unbounded_channel();
        let log = Arc::new(Mutex::new(Vec::new()));
        let reader = {
            let (log, errors, id) = (log.clone(), self.schema_errors.clone(), id.to_owned());
            tokio::spawn(async move {
                while let Some(Ok(msg)) = stream.next().await {
                    let Message::Text(text) = msg else { continue };
                    let m: Value = match serde_json::from_str(text.as_str()) {
                        Ok(m) => m,
                        Err(e) => {
                            errors
                                .lock()
                                .unwrap()
                                .push(format!("-> {id}: not JSON: {e}"));
                            continue;
                        }
                    };
                    for e in validate_message(&m) {
                        errors
                            .lock()
                            .unwrap()
                            .push(format!("{} -> {id}: {e}", m["t"]));
                    }
                    log.lock().unwrap().push(m.clone());
                    let _ = tx.send(m);
                }
            })
        };
        Client {
            id: id.to_owned(),
            room_id: room.room_id.clone(),
            sink,
            rx,
            inbox: Vec::new(),
            log,
            reader,
            seq: 0,
            pings: 0,
        }
    }

    /// Connects and says hello; returns the client and its welcome.
    pub async fn join(&self, id: &str, room: &RoomInfo) -> (Client, Value) {
        let mut client = self.connect(id, room).await;
        let info = json!({ "id": id, "name": id, "ver": "test" });
        client
            .send("hello", json!({ "proto": 1, "client": info }))
            .await;
        let welcome = client.next("welcome").await;
        (client, welcome)
    }

    /// Opens a socket, immediately sends `hello`, and reports the close code and how many
    /// messages arrived before the close.
    pub async fn connect_expecting_close(&self, room_id: &str, token: &str) -> (u16, usize) {
        let (ws, _) = connect_async(self.ws_url(room_id, token)).await.unwrap();
        let (mut sink, mut stream) = ws.split();
        let hello = json!({
            "v": 1, "t": "hello", "room": room_id, "seq": 0, "ts": now_ms(), "from": "intruder",
            "proto": 1, "client": { "id": "intruder", "name": "intruder", "ver": "test" },
        });
        let _ = sink.send(Message::text(hello.to_string())).await;
        let (mut code, mut messages) = (None, 0);
        let closed = timeout(DEFAULT_WAIT, async {
            while let Some(Ok(msg)) = stream.next().await {
                match msg {
                    Message::Close(frame) => code = frame.map(|f| u16::from(f.code)),
                    Message::Text(_) | Message::Binary(_) => messages += 1,
                    _ => {}
                }
            }
        })
        .await;
        assert!(
            closed.is_ok(),
            "server did not close the socket within 1000 ms"
        );
        (code.expect("close frame carries a code"), messages)
    }
}

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub struct Client {
    pub id: String,
    room_id: String,
    sink: SplitSink<Ws, Message>,
    rx: mpsc::UnboundedReceiver<Value>,
    /// Received but not yet consumed by `next*`.
    inbox: Vec<Value>,
    /// Every message received from the server, in arrival order.
    log: Arc<Mutex<Vec<Value>>>,
    reader: JoinHandle<()>,
    seq: u64,
    pings: u64,
}

impl Client {
    /// Sends a schema-valid message; the envelope fields are filled in.
    pub async fn send(&mut self, t: &str, body: Value) {
        let mut msg = json!({
            "v": 1, "t": t, "room": self.room_id, "seq": self.seq, "ts": now_ms(), "from": self.id,
        });
        self.seq += 1;
        let fields = msg.as_object_mut().unwrap();
        for (k, v) in body.as_object().expect("body is an object") {
            fields.insert(k.clone(), v.clone());
        }
        let errs = validate_message(&msg);
        assert!(
            errs.is_empty(),
            "test tried to send an off-schema {t}: {errs:?}"
        );
        self.send_raw(&msg.to_string()).await;
    }

    /// Sends raw text, bypassing schema checks (for malformed-input tests).
    pub async fn send_raw(&mut self, data: &str) {
        self.sink.send(Message::text(data)).await.unwrap();
    }

    pub async fn intent(&mut self, op: &str, args: Value) {
        self.send("intent", json!({ "op": op, "args": args })).await;
    }

    /// The first not-yet-consumed message with this `t`, waiting up to 1000 ms.
    pub async fn next(&mut self, t: &str) -> Value {
        self.next_where(t, |m| m["t"] == t, DEFAULT_WAIT).await
    }

    /// The first not-yet-consumed message matching `pred`.
    pub async fn next_where(
        &mut self,
        what: &str,
        pred: impl Fn(&Value) -> bool,
        wait: Duration,
    ) -> Value {
        if let Some(i) = self.inbox.iter().position(&pred) {
            return self.inbox.remove(i);
        }
        let deadline = Instant::now() + wait;
        loop {
            match timeout_at(deadline, self.rx.recv()).await {
                Ok(Some(m)) if pred(&m) => return m,
                Ok(Some(m)) => self.inbox.push(m),
                Ok(None) => panic!("{}: connection closed while waiting for {what}", self.id),
                Err(_) => panic!("{}: no matching message within {wait:?} ({what})", self.id),
            }
        }
    }

    pub fn log(&self) -> Vec<Value> {
        self.log.lock().unwrap().clone()
    }

    pub fn log_types(&self) -> Vec<String> {
        self.log()
            .iter()
            .map(|m| m["t"].as_str().unwrap().to_owned())
            .collect()
    }

    pub fn count(&self, t: &str) -> usize {
        self.log().iter().filter(|m| m["t"] == t).count()
    }

    /// Clock round-trip: once the pong arrives, everything this client sent earlier has been
    /// processed and everything the server queued for it earlier has arrived.
    pub async fn sync(&mut self) {
        let ping_id = format!("sync-{}", self.pings);
        self.pings += 1;
        self.send("clock_ping", json!({ "ping_id": ping_id, "t0": now_ms() }))
            .await;
        let is_pong = |m: &Value| m["t"] == "clock_pong" && m["ping_id"] == ping_id.as_str();
        self.next_where("sync pong", is_pong, DEFAULT_WAIT).await;
    }

    /// Closes the socket and waits for the server's close reply.
    pub async fn close(mut self) {
        let _ = self.sink.close().await;
        let _ = timeout(DEFAULT_WAIT, &mut self.reader).await;
    }
}
