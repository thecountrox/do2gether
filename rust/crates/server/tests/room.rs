//! Port of `server/test/room.test.ts` (AC1–AC10 and the other TASK.md behaviour), plus the
//! `docs/02-decisions.md` deltas: rejects, seq-vs-rev, presence keyed by user, 4004.

mod support;

use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use hyper::{Method, StatusCode};
use serde_json::{Value, json};
use sha2::Sha256;
use support::*;
use tokio::time::sleep;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use wt_protocol::Observed;
use wt_server::tokens::sign_token_for;
use wt_server::tokens::{sign_token, sign_token_with_ttl, verify_token};

fn is_leave(m: &Value) -> bool {
    m["t"] == "presence" && m["action"] == "leave"
}

// ---------------------------------------------------------------------------
// Acceptance criteria (TASK.md)
// ---------------------------------------------------------------------------

#[test]
fn harness_schema_validator_accepts_valid_and_rejects_off_schema_messages() {
    let ok = json!({ "v": 1, "t": "state", "room": "r", "seq": 0, "ts": 0, "from": "server",
                     "rev": 0, "playback": null, "queue": [] });
    assert_eq!(validate_message(&ok), Vec::<String>::new());

    let mut bad_playback = ok.clone();
    bad_playback["playback"] = json!({ "item_ref": "bogus", "anchor_server_ms": 1.5,
                                       "position_ms": -1, "rate": 1, "paused": false });
    assert!(!validate_message(&bad_playback).is_empty());

    let mut bad_type = ok.clone();
    bad_type["t"] = json!("nope");
    assert!(!validate_message(&bad_type).is_empty());

    let mut no_rev = ok.clone();
    no_rev.as_object_mut().unwrap().remove("rev");
    assert!(!validate_message(&no_rev).is_empty());

    let mut welcome = json!({"v":1,"t":"welcome","room":"r","seq":0,"ts":0,"from":"server", "server_now":0,
        "snapshot":{"rev":0,"playback":null,"queue":[],"presence":[],"meta":{"host_id":"h","host_name":"Host","controls":"host","locked":false}}});
    assert!(validate_message(&welcome).is_empty());
    welcome["snapshot"]["meta"]["controls"] = json!("everyone");
    assert!(!validate_message(&welcome).is_empty());

    let reject = json!({ "v": 1, "t": "reject", "room": "r", "seq": 0, "ts": 0, "from": "server",
                         "code": "intent_rejected", "message": "nothing is playing", "req_id": "r1" });
    assert_eq!(validate_message(&reject), Vec::<String>::new());
}

#[tokio::test]
async fn ac1_post_rooms_returns_room_id_and_join_token() {
    let server = Server::start().await;
    let (status, content_type, body) = server.http(Method::POST, "/rooms").await;
    assert_eq!(status, StatusCode::CREATED);
    assert!(
        content_type
            .as_deref()
            .unwrap_or("")
            .starts_with("application/json"),
        "content-type {content_type:?}"
    );
    let a: RoomInfo = serde_json::from_slice(&body).unwrap();
    let b = server.create_room().await;

    for r in [&a, &b] {
        assert!(!r.host_id.is_empty());
        assert_eq!(r.room_id.len(), 8, "{}", r.room_id);
        assert!(
            r.room_id
                .bytes()
                .all(|c| c.is_ascii_digit() || c.is_ascii_lowercase()),
            "{}",
            r.room_id
        );
        assert_eq!(
            verify_token(&r.join_token, &r.room_id)
                .unwrap()
                .sub
                .as_deref(),
            Some(r.host_id.as_str())
        );
        assert!(
            server.state.room(&r.room_id).is_some(),
            "room exists server-side"
        );
    }
    assert_ne!(a.room_id, b.room_id);
    assert!(
        verify_token(&a.join_token, &b.room_id).is_none(),
        "token is bound to its room"
    );

    // Token format: base64url({"room","exp"}) "." base64url(HMAC-SHA256(room:exp)), 10 minute TTL.
    let parts: Vec<&str> = a.join_token.split('.').collect();
    assert_eq!(parts.len(), 2);
    let claims: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
    assert_eq!(claims["room"], a.room_id.as_str());
    assert_eq!(claims["sub"], a.host_id.as_str());
    let exp = int(&claims["exp"]);
    let ttl = exp - now_ms();
    assert!(ttl > 9 * 60_000 && ttl <= 10 * 60_000, "ttl {ttl}");

    let secret = std::env::var("WT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev-secret".into());
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(format!("{}:{exp}:{}", a.room_id, a.host_id).as_bytes());
    assert_eq!(
        parts[1],
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    );
}

#[tokio::test]
async fn ac2_bad_tokens_are_closed_with_4001_and_never_join() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let other = server.create_room().await;
    let (mut observer, _) = server.join("observer", &room).await;

    let (payload, sig) = room.join_token.split_once('.').unwrap();
    let mut claims: Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).unwrap()).unwrap();
    claims["exp"] = json!(int(&claims["exp"]) + 3_600_000);
    let extended = URL_SAFE_NO_PAD.encode(claims.to_string());

    let expired = sign_token_with_ttl(&room.room_id, 100);
    assert!(
        verify_token(&expired, &room.room_id).is_some(),
        "short-TTL token is valid before expiry"
    );
    sleep(Duration::from_millis(150)).await;
    assert!(
        verify_token(&expired, &room.room_id).is_none(),
        "short-TTL token fails after expiry"
    );

    let cases = [
        ("garbage", "not-a-token".to_owned()),
        ("empty", String::new()),
        ("wrong room", other.join_token.clone()),
        ("tampered exp", format!("{extended}.{sig}")),
        ("expired", expired),
    ];
    for (label, token) in &cases {
        let (code, messages) = server.connect_expecting_close(&room.room_id, token).await;
        assert_eq!(code, 4001, "{label}: close code");
        assert_eq!(messages, 0, "{label}: no messages before close");
    }

    let attached = server.room(&room.room_id).lock().unwrap().client_count();
    assert_eq!(attached, 1, "only the observer is attached");
    observer.sync().await;
    assert_eq!(
        observer.count("presence"),
        0,
        "no presence join for rejected sockets"
    );
}

#[tokio::test]
async fn bound_hello_rejects_wrong_identity_without_presence_and_accepts_owner() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut observer, _) = server.join("observer", &room).await;
    let token = sign_token_for(&room.room_id, Some("ann"));
    let (mut ws, _) = connect_async(server.ws_url(&room.room_id, &token))
        .await
        .unwrap();
    ws.send(Message::text(json!({"v":1,"t":"hello","room":room.room_id,"seq":0,"ts":now_ms(),"from":"bob","proto":1,"client":{"id":"bob","name":"Bob","ver":"test"}}).to_string())).await.unwrap();
    let frame = tokio::time::timeout(Duration::from_secs(1), ws.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let Message::Close(Some(frame)) = frame else {
        panic!("expected close frame")
    };
    assert_eq!(u16::from(frame.code), 4001);
    assert_eq!(frame.reason, "identity mismatch");
    server.wait_for_clients(&room.room_id, 1).await;
    observer.sync().await;
    assert_eq!(observer.count("presence"), 0);
    assert_eq!(server.room(&room.room_id).lock().unwrap().seq, 1);
    let bound = RoomInfo {
        join_token: token,
        ..room.clone()
    };
    let (_, welcome) = server.join("ann", &bound).await;
    assert_eq!(presence_ids(&welcome), ["ann", "observer"]);
}

#[tokio::test]
async fn unbound_token_accepts_any_hello_identity() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let manual = RoomInfo {
        join_token: sign_token(&room.room_id),
        ..room
    };
    let (_, welcome) = server.join("bob", &manual).await;
    assert_eq!(presence_ids(&welcome), ["bob"]);
}

#[tokio::test]
async fn join_page_renders_valid_link_and_rejects_invalid_or_expired() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (status, kind, body) = server
        .http(Method::GET, &format!("/join/{}", room.join_token))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(kind.unwrap().starts_with("text/html"));
    let html = String::from_utf8(body.to_vec()).unwrap();
    assert!(html.contains(&format!(
        "watchtogether://join?room={}&amp;token={}",
        room.room_id, room.join_token
    )));
    assert!(html.contains(&format!(
        "wt-play --server http://{} --room {} --token {} --file &lt;path&gt;",
        server.addr, room.room_id, room.join_token
    )));
    assert!(html.contains("Copy room id") && html.contains("Copy token"));
    for token in ["garbage".to_owned(), sign_token_with_ttl(&room.room_id, -1)] {
        let (status, _, body) = server.http(Method::GET, &format!("/join/{token}")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(
            String::from_utf8(body.to_vec())
                .unwrap()
                .contains("this link expired")
        );
    }
}

#[tokio::test]
async fn ac3_hello_welcome_and_presence_join() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, wa) = server.join("alice", &room).await;
    assert_eq!(wa["room"], room.room_id.as_str());
    assert_eq!(wa["snapshot"]["rev"], 0);
    assert_eq!(wa["snapshot"]["playback"], Value::Null);
    assert_eq!(wa["snapshot"]["queue"], json!([]));
    assert_eq!(presence_ids(&wa), ["alice"]);
    assert!(
        (int(&wa["server_now"]) - now_ms()).abs() < 1000,
        "server_now is server ms"
    );

    // A hello with the wrong proto is ignored: no welcome, no membership.
    let mut c = server.connect("mallory", &room).await;
    let bad_hello = json!({
        "v": 1, "t": "hello", "room": room.room_id, "seq": 0, "ts": now_ms(), "from": "mallory",
        "proto": 2, "client": { "id": "mallory", "name": "mallory", "ver": "test" },
    });
    c.send_raw(&bad_hello.to_string()).await;

    let (mut b, wb) = server.join("bob", &room).await;
    assert_eq!(presence_ids(&wb), ["alice", "bob"]);

    let joined = a.next("presence").await;
    assert_eq!(joined["user_id"], "bob");
    assert_eq!(joined["action"], "join");

    b.sync().await;
    assert_eq!(
        b.count("presence"),
        0,
        "joiner does not get its own presence join"
    );
    assert_eq!(c.count("welcome"), 0, "proto != 1 gets no welcome");
}

#[tokio::test]
async fn ac4_clock_offset_over_10_pings_is_within_50ms() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let mut offsets = Vec::new();
    for i in 0..10 {
        let ping_id = format!("p{i}");
        let t0 = now_ms();
        a.send("clock_ping", json!({ "ping_id": ping_id, "t0": t0 }))
            .await;
        let is_pong = |m: &Value| m["t"] == "clock_pong" && m["ping_id"] == ping_id.as_str();
        let pong = a
            .next_where("clock_pong", is_pong, Duration::from_millis(1000))
            .await;
        let t3 = now_ms();
        let (t1, t2) = (int(&pong["t1"]), int(&pong["t2"]));
        assert_eq!(int(&pong["t0"]), t0, "t0 echoed");
        assert!(
            t0 <= t1 && t1 <= t2 && t2 <= t3,
            "t0..t3 ordered: {t0} {t1} {t2} {t3}"
        );
        offsets.push(((t1 - t0) + (t2 - t3)) as f64 / 2.0);
    }
    offsets.sort_by(f64::total_cmp);
    let median = (offsets[4] + offsets[5]) / 2.0;
    assert!(median.abs() <= 50.0, "median offset {median} ms");
}

#[tokio::test]
async fn ac5_play_reaches_other_client_as_state_within_500ms() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (mut b, _) = server.join("bob", &room).await;
    a.next("presence").await;

    a.intent("play", json!({})).await; // rejected: nothing playing and no item_ref
    let sent_at = now_ms();
    a.intent("play", json!({ "item_ref": FILM })).await;
    let s = b
        .next_where("state", |m| m["t"] == "state", Duration::from_millis(500))
        .await;
    let received_at = now_ms();

    assert!(
        received_at - sent_at < 500,
        "latency {} ms",
        received_at - sent_at
    );
    assert_eq!(s["rev"], 1, "the rejected play did not count");
    let pb = &s["playback"];
    assert_eq!(pb["item_ref"], FILM);
    assert_eq!(pb["paused"], false);
    assert_eq!(pb["rate"], 1);
    assert_eq!(pb["position_ms"], 0);
    let anchor = int(&pb["anchor_server_ms"]);
    assert!(
        sent_at <= anchor && anchor <= received_at,
        "anchor is server now at accept time"
    );

    let own = a.next("state").await;
    assert_eq!(own, s, "sender receives the identical broadcast");
    let reject = a.next("reject").await;
    assert_eq!(reject["message"], "nothing is playing");
}

#[tokio::test]
async fn ac6_pause_freezes_position_at_elapsed_time() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    a.intent("play", json!({ "item_ref": FILM, "position_ms": 0 }))
        .await;
    let played = a.next("state").await;
    let played_anchor = int(&played["playback"]["anchor_server_ms"]);

    sleep(Duration::from_millis(300)).await;
    a.intent("pause", json!({})).await;
    let paused = a.next("state").await;
    let elapsed = now_ms() - played_anchor;

    let pb = &paused["playback"];
    let position = int(&pb["position_ms"]);
    assert_eq!(pb["paused"], true);
    assert_eq!(pb["item_ref"], FILM);
    assert!(position >= 290, "position {position}");
    assert!(
        (position - elapsed).abs() <= 100,
        "position {position} vs elapsed {elapsed}"
    );
    assert_eq!(
        position,
        int(&pb["anchor_server_ms"]) - played_anchor,
        "anchor reset to pause time; position advanced 1:1 at rate 1"
    );
}

#[tokio::test]
async fn ac7_seek_sets_position_and_preserves_item_rate_paused() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    a.intent("play", json!({ "item_ref": FILM })).await;
    let played = a.next("state").await;

    a.intent("seek", json!({ "position_ms": 42000 })).await;
    let s = a.next("state").await;
    let pb = &s["playback"];
    assert_eq!(pb["position_ms"], 42000);
    assert_eq!(pb["item_ref"], FILM);
    assert_eq!(pb["rate"], 1);
    assert_eq!(pb["paused"], false);
    assert!(int(&pb["anchor_server_ms"]) >= int(&played["playback"]["anchor_server_ms"]));

    a.intent("pause", json!({})).await;
    a.next("state").await;
    a.intent("seek", json!({ "position_ms": 1000 })).await;
    let s2 = a.next("state").await;
    assert_eq!(s2["playback"]["position_ms"], 1000);
    assert_eq!(
        s2["playback"]["paused"], true,
        "seek while paused stays paused"
    );
}

#[tokio::test]
async fn ac8_rev_and_seq_increase_monotonically_across_five_intents() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, wa) = server.join("alice", &room).await;
    let (mut b, wb) = server.join("bob", &room).await;
    a.next("presence").await;

    a.intent("seek", json!({ "position_ms": 5 })).await; // rejected: nothing playing
    let ops = [
        ("queue_add", json!({ "item_ref": SONG })),
        ("play", json!({ "item_ref": FILM })),
        ("seek", json!({ "position_ms": 42000 })),
        ("pause", json!({})),
        ("skip", json!({})),
    ];
    let (mut seen_a, mut seen_b) = (Vec::new(), Vec::new());
    for (i, (op, args)) in ops.into_iter().enumerate() {
        let sender = if i % 2 == 0 && op == "queue_add" {
            &mut b
        } else {
            &mut a
        };
        sender.intent(op, args).await;
        seen_a.push(a.next("state").await);
        seen_b.push(b.next("state").await);
    }

    let revs: Vec<i64> = seen_a.iter().map(|s| int(&s["rev"])).collect();
    assert_eq!(revs, [1, 2, 3, 4, 5]);
    let seqs = |w: &Value, seen: &[Value]| -> Vec<i64> {
        std::iter::once(w)
            .chain(seen)
            .map(|m| int(&m["seq"]))
            .collect()
    };
    assert_strictly_increasing(&seqs(&wa, &seen_a), "seq (alice)");
    assert_strictly_increasing(&seqs(&wb, &seen_b), "seq (bob)");
    assert_eq!(seen_b, seen_a, "both clients see the same state stream");

    let last = seen_a.last().unwrap();
    assert_eq!(
        last["playback"]["item_ref"], SONG,
        "skip popped the queue head into playback"
    );
    assert_eq!(last["playback"]["position_ms"], 0);
    assert_eq!(last["queue"], json!([]));
}

#[tokio::test]
async fn ac9_reconnecting_client_gets_welcome_matching_latest_state() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (b, _) = server.join("bob", &room).await;

    a.intent("play", json!({ "item_ref": FILM, "position_ms": 10_000 }))
        .await;
    a.next("state").await;
    a.intent("seek", json!({ "position_ms": 60_000 })).await;
    let latest = a.next("state").await;

    b.close().await;
    let left = a
        .next_where("presence leave", is_leave, Duration::from_millis(1000))
        .await;
    assert_eq!(left["user_id"], "bob");
    let attached = server.room(&room.room_id).lock().unwrap().client_count();
    assert_eq!(attached, 1, "presence removed on disconnect");

    sleep(Duration::from_millis(200)).await;
    let (b2, welcome) = server.join("bob", &room).await;
    let received_at = now_ms();
    let pb = &welcome["snapshot"]["playback"];
    assert_eq!(welcome["snapshot"]["rev"], latest["rev"]);
    assert_eq!(pb["item_ref"], latest["playback"]["item_ref"]);
    assert_eq!(pb["paused"], latest["playback"]["paused"]);
    let from_welcome = position_at(pb, int(&welcome["server_now"]));
    let from_latest = position_at(&latest["playback"], received_at);
    assert!(
        (from_welcome - from_latest).abs() <= 150.0,
        "welcome {from_welcome} vs latest {from_latest}"
    );
    assert!(
        from_welcome >= 60_190.0,
        "playback kept running while bob was away ({from_welcome})"
    );
    assert_eq!(
        presence_ids(&welcome),
        ["alice", "bob"],
        "no stale presence entry"
    );

    // Same check while paused: position must match exactly.
    a.intent("pause", json!({})).await;
    let paused_state = a.next("state").await;
    b2.close().await;
    let (_b3, w3) = server.join("bob", &room).await;
    assert_eq!(w3["snapshot"]["playback"], paused_state["playback"]);
    assert_eq!(w3["snapshot"]["rev"], paused_state["rev"]);
}

#[tokio::test]
async fn ac10_report_is_stored_per_client_and_never_broadcast() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (mut b, _) = server.join("bob", &room).await;
    a.next("presence").await;

    let first = json!({ "offset_ms": 1.5, "rtt_ms": 12, "drift_ms": -30, "source": "mpv" });
    let second = json!({ "offset_ms": 2, "rtt_ms": 9.5, "drift_ms": 4, "source": "mpv" });
    a.send("report", json!({ "activity_id": null, "observed": first }))
        .await;
    a.send("report", json!({ "activity_id": null, "observed": second }))
        .await;
    a.sync().await;

    {
        let shared = server.room(&room.room_id);
        let room = shared.lock().unwrap();
        let report = room.report_for("alice").expect("report stored");
        let expected = Observed {
            offset_ms: 2.0,
            rtt_ms: 9.5,
            drift_ms: 4.0,
            source: "mpv".into(),
        };
        assert_eq!(report.observed, expected, "latest report wins");
        assert_eq!(report.activity_id, None);
        assert!(room.report_for("bob").is_none(), "reports are per client");
    }

    a.intent("play", json!({ "item_ref": CLIP })).await;
    b.next("state").await;
    sleep(Duration::from_millis(100)).await;
    assert_eq!(b.log_types(), ["welcome", "state"], "bob saw no report");
    assert_eq!(a.count("report"), 0, "report not echoed to sender");
}

// ---------------------------------------------------------------------------
// Other TASK.md behaviour
// ---------------------------------------------------------------------------

#[tokio::test]
async fn http_health_is_ok_and_everything_else_is_404() {
    let server = Server::start().await;
    let (status, _, body) = server.http(Method::GET, "/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({ "ok": true })
    );

    for (method, path) in [
        (Method::GET, "/"),
        (Method::GET, "/rooms"),
        (Method::POST, "/health"),
        (Method::GET, "/nope"),
        (Method::GET, "/ws"),
    ] {
        let (status, _, _) = server.http(method.clone(), path).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{method} {path}");
    }
}

#[tokio::test]
async fn malformed_input_is_ignored_without_disconnecting() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (mut b, _) = server.join("bob", &room).await;
    a.next("presence").await;

    let env = |extra: Value| {
        let mut m =
            json!({ "v": 1, "room": room.room_id, "seq": 0, "ts": now_ms(), "from": "alice" });
        for (k, v) in extra.as_object().unwrap() {
            m[k] = v.clone();
        }
        m.to_string()
    };
    let raws = [
        "{not json".to_owned(),
        String::new(),
        "null".to_owned(),
        "[]".to_owned(),
        "42".to_owned(),
        env(json!({ "v": 2, "t": "intent", "op": "play", "args": { "item_ref": FILM } })),
        env(json!({ "t": "bogus" })),
        env(json!({ "t": "intent", "op": "explode", "args": {} })),
        // Known op, refused args: these two are answered with `reject` (docs/02-decisions.md).
        env(json!({ "t": "intent", "op": "play", "args": "nope" })),
        env(json!({ "t": "intent", "op": "play", "args": { "item_ref": "not-a-ref" } })),
    ];
    for raw in &raws {
        a.send_raw(raw).await;
    }
    a.sync().await;

    a.intent("play", json!({ "item_ref": FILM })).await;
    let s = b.next("state").await;
    assert_eq!(s["rev"], 1, "none of the ignored messages changed state");
    assert_eq!(b.log_types(), ["welcome", "state"]);
    assert_eq!(
        a.count("reject"),
        2,
        "only the known-op intents are answered"
    );
}

#[tokio::test]
async fn rooms_are_isolated() {
    let server = Server::start().await;
    let r1 = server.create_room().await;
    let r2 = server.create_room().await;
    let (mut a, _) = server.join("alice", &r1).await;
    let (mut b, welcome) = server.join("bob", &r2).await;
    assert_eq!(presence_ids(&welcome), ["bob"]);

    a.intent("play", json!({ "item_ref": FILM })).await;
    a.next("state").await;
    b.sync().await;
    assert_eq!(b.log_types(), ["welcome", "clock_pong"]);
    let shared = server.room(&r2.room_id);
    let r2_state = shared.lock().unwrap();
    assert_eq!(r2_state.playback, None);
    assert_eq!(r2_state.rev, 0);
}

#[tokio::test]
async fn queue_add_remove_and_skip() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    async fn step(a: &mut Client, op: &str, args: Value) -> Value {
        a.intent(op, args).await;
        a.next("state").await
    }

    let s = step(&mut a, "queue_add", json!({ "item_ref": SONG })).await;
    assert_eq!(s["queue"], json!([{ "item_ref": SONG }]));
    let s = step(&mut a, "queue_add", json!({ "item_ref": CLIP })).await;
    assert_eq!(
        s["queue"],
        json!([{ "item_ref": SONG }, { "item_ref": CLIP }])
    );
    let s = step(&mut a, "queue_remove", json!({ "item_ref": SONG })).await;
    assert_eq!(s["queue"], json!([{ "item_ref": CLIP }]));

    let skipped = step(&mut a, "skip", json!({})).await;
    assert_eq!(skipped["queue"], json!([]));
    assert_eq!(skipped["playback"]["item_ref"], CLIP);
    assert_eq!(skipped["playback"]["position_ms"], 0);
    assert_eq!(skipped["playback"]["paused"], false);

    let cleared = step(&mut a, "skip", json!({})).await;
    assert_eq!(
        cleared["playback"],
        Value::Null,
        "skip with an empty queue clears playback"
    );
    assert_eq!(cleared["rev"], 5);
}

// ---------------------------------------------------------------------------
// docs/02-decisions.md
// ---------------------------------------------------------------------------

#[tokio::test]
async fn refused_intents_get_a_reject_to_the_sender_only() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (mut b, _) = server.join("bob", &room).await;
    let joined = a.next("presence").await;

    let cases = [
        ("pause", json!({}), "nothing is playing"),
        ("play", json!({}), "nothing is playing"),
        ("seek", json!({ "position_ms": 5 }), "nothing is playing"),
        ("skip", json!({}), "queue is empty and nothing is playing"),
        (
            "queue_remove",
            json!({ "item_ref": SONG }),
            "item_ref is not in the queue",
        ),
        (
            "queue_add",
            json!({ "item_ref": "nope" }),
            "item_ref is not a valid item_ref",
        ),
        (
            "seek",
            json!({ "position_ms": -1 }),
            "position_ms must be a non-negative integer",
        ),
    ];
    for (i, (op, args, message)) in cases.into_iter().enumerate() {
        let req_id = format!("req-{i}");
        a.send("intent", json!({ "op": op, "args": args, "id": req_id }))
            .await;
        let reject = a.next("reject").await;
        assert_eq!(reject["code"], "intent_rejected", "{op}");
        assert_eq!(reject["message"], message, "{op}");
        assert_eq!(
            reject["req_id"],
            req_id.as_str(),
            "{op}: req_id echoes the intent id"
        );
        assert_eq!(
            reject["seq"], joined["seq"],
            "{op}: a unicast reject does not bump seq"
        );
    }

    // Without an `id` there is nothing to echo.
    a.intent("pause", json!({})).await;
    let reject = a.next("reject").await;
    assert!(reject.get("req_id").is_none(), "{reject}");

    b.sync().await;
    assert_eq!(
        b.log_types(),
        ["welcome", "clock_pong"],
        "nothing reaches other clients"
    );
    assert_eq!(
        a.count("state"),
        0,
        "no state broadcast for a refused intent"
    );
    {
        let shared = server.room(&room.room_id);
        let r = shared.lock().unwrap();
        let seq = joined["seq"].as_u64().unwrap();
        assert_eq!(
            (r.rev, r.seq),
            (0, seq),
            "rejects change neither rev nor seq"
        );
    }

    a.intent("play", json!({ "item_ref": FILM })).await;
    let s = b.next("state").await;
    assert_eq!(s["rev"], 1);
    assert_eq!(int(&s["seq"]), int(&joined["seq"]) + 1);
}

#[tokio::test]
async fn seq_counts_every_broadcast_while_rev_counts_only_content() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut a, _) = server.join("alice", &room).await;
    let (_b, _) = server.join("bob", &room).await;
    a.intent("play", json!({ "item_ref": FILM })).await;
    a.next("state").await;
    let (carol, wc) = server.join("carol", &room).await;
    assert_eq!(wc["snapshot"]["rev"], 1, "presence did not bump rev");
    carol.close().await;
    a.next_where("carol leaves", is_leave, Duration::from_millis(1000))
        .await;
    a.intent("pause", json!({})).await;
    a.next("state").await;

    let seen: Vec<(String, i64, Option<i64>)> = a
        .log()
        .iter()
        .map(|m| {
            (
                m["t"].as_str().unwrap().to_owned(),
                int(&m["seq"]),
                m["rev"].as_i64(),
            )
        })
        .collect();
    // Alice's own join (seq 1) went to nobody else; her welcome carries it.
    let expected = [
        ("welcome", 1, None),
        ("presence", 2, None), // bob joins
        ("state", 3, Some(1)),
        ("presence", 4, None), // carol joins
        ("presence", 5, None), // carol leaves
        ("state", 6, Some(2)),
    ]
    .map(|(t, seq, rev)| (t.to_owned(), seq, rev));
    assert_eq!(seen, expected);
}

#[tokio::test]
async fn presence_is_keyed_by_user_across_connections() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (a1, _) = server.join("alice", &room).await;
    let (mut b, _) = server.join("bob", &room).await;

    let (mut a2, w2) = server.join("alice", &room).await;
    assert_eq!(
        presence_ids(&w2),
        ["alice", "bob"],
        "snapshot lists each user once"
    );
    b.sync().await;
    assert_eq!(
        b.count("presence"),
        0,
        "a second connection does not announce a join"
    );

    a2.intent("play", json!({ "item_ref": CLIP })).await;
    a2.next("state").await;

    a1.close().await;
    server.wait_for_clients(&room.room_id, 2).await;
    b.sync().await;
    assert_eq!(
        b.count("presence"),
        0,
        "no leave while alice still has a connection"
    );

    a2.close().await;
    let left = b
        .next_where("alice leaves", is_leave, Duration::from_millis(1000))
        .await;
    assert_eq!(left["user_id"], "alice");
    assert_eq!(b.count("presence"), 1, "exactly one leave");
}

#[tokio::test]
async fn valid_token_for_unknown_room_closes_with_4004() {
    let server = Server::start().await;
    let (code, messages) = server
        .connect_expecting_close("zzzzzzzz", &sign_token("zzzzzzzz"))
        .await;
    assert_eq!(code, 4004);
    assert_eq!(messages, 0);
}

#[tokio::test]
async fn host_controls_permissions_and_meta_are_broadcast() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut host, welcome) = server.join("alice", &room).await;
    let (mut guest, _) = server.join("guest", &room).await;
    host.next("presence").await;
    assert_eq!(
        welcome["snapshot"]["meta"],
        json!({"host_id":"alice","host_name":"alice","controls":"host","locked":false})
    );
    guest.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(guest.next("reject").await["code"], "not_host");
    guest.intent("queue_add", json!({"item_ref": SONG})).await;
    assert_eq!(guest.next("state").await["rev"], 1);
    host.next("state").await;
    host.intent("set_controls", json!({"controls":"all"})).await;
    let updated = guest.next("state").await;
    assert_eq!(updated["rev"], 2);
    assert_eq!(updated["meta"]["controls"], "all");
    host.next("state").await;
    guest.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(guest.next("state").await["rev"], 3);
    host.next("state").await;
    guest.intent("lock", json!({"locked":true})).await;
    assert_eq!(guest.next("reject").await["code"], "not_host");
    host.intent("lock", json!({"locked":true})).await;
    let locked = host.next("state").await;
    assert_eq!(locked["meta"]["locked"], true);
    guest.next("state").await;
    assert_eq!(
        server.connect_expecting_close(&room.room_id, "bad").await.0,
        4001
    );
    assert_eq!(
        server
            .connect_expecting_close(&room.room_id, &room.join_token)
            .await
            .0,
        4003
    );
    guest.intent("pause", json!({})).await;
    assert_eq!(guest.next("reject").await["code"], "locked");
    host.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(host.next("state").await["meta"]["locked"], true);
    guest.next("state").await;
    host.intent("lock", json!({"locked":false})).await;
    assert_eq!(host.next("state").await["meta"]["locked"], false);
    let (_, fresh) = server.join("fresh", &room).await;
    assert_eq!(fresh["snapshot"]["meta"]["controls"], "all");
    assert_eq!(fresh["snapshot"]["meta"]["locked"], false);
}

#[tokio::test]
async fn kick_closes_every_target_connection_and_removes_presence() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut host, _) = server.join("alice", &room).await;
    let (mut raw, _) = connect_async(server.ws_url(&room.room_id, &sign_token(&room.room_id)))
        .await
        .unwrap();
    raw.send(Message::text(json!({"v":1,"t":"hello","room":room.room_id,"seq":0,"ts":now_ms(),"from":"guest","proto":1,"client":{"id":"guest","name":"guest","ver":"test"}}).to_string())).await.unwrap();
    let welcome = raw.next().await.unwrap().unwrap();
    assert!(matches!(welcome, Message::Text(_)));
    let (_guest2, _) = server.join("guest", &room).await;
    host.next("presence").await;
    host.intent("kick", json!({"user_id":"alice"})).await;
    assert_eq!(host.next("reject").await["code"], "intent_rejected");
    host.intent("kick", json!({"user_id":"guest"})).await;
    assert_eq!(host.next("presence").await["action"], "leave");
    server.wait_for_clients(&room.room_id, 1).await;
    assert_eq!(server.room(&room.room_id).lock().unwrap().member_count(), 1);
    assert_eq!(server.room(&room.room_id).lock().unwrap().rev, 0);
    let frame = tokio::time::timeout(Duration::from_secs(1), raw.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let Message::Close(Some(frame)) = frame else {
        panic!("expected kicked close: {frame:?}")
    };
    assert_eq!(u16::from(frame.code), 4005);
    assert_eq!(frame.reason, "kicked");
}
