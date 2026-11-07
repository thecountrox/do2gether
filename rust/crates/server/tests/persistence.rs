#[allow(dead_code)]
mod support;

use std::path::Path;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use hyper::{Method, StatusCode};
use rusqlite::Connection;
use serde_json::{Value, json};
use support::*;
use tempfile::tempdir;
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use wt_server::{AppState, Limits, store::Store};

fn open(path: &Path, limits: Limits) -> AppState {
    AppState::open(path, limits).unwrap()
}

#[tokio::test]
async fn restart_restores_playback_queue_revision_and_metadata() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("rooms.db");
    let state = open(&path, Limits::default());
    let server = Server::start_with_state(state).await;
    let metadata =
        json!({"host_id":"h1","host_name":"Host","guild_id":"g1","voice_channel_id":"v1"});
    let (status, _, body) = server
        .http_body(Method::POST, "/rooms", metadata.to_string().into())
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let info: RoomInfo = serde_json::from_slice(&body).unwrap();
    let (mut client, _) = server.join("alice", &info).await;
    client
        .intent("play", json!({"item_ref": FILM, "position_ms": 1234}))
        .await;
    let played = client.next("state").await;
    client.intent("queue_add", json!({"item_ref": SONG})).await;
    let queued = client.next("state").await;
    client.close().await;
    server.wait_for_clients(&info.room_id, 0).await;
    drop(server);
    let reopened = open(&path, Limits::default());
    let room = reopened.room(&info.room_id).unwrap();
    let r = room.lock().unwrap();
    assert_eq!(r.rev, 2);
    assert_eq!(r.seq, 4); // join, two intents, leave
    assert_eq!(
        serde_json::to_value(&r.playback).unwrap(),
        played["playback"]
    );
    assert_eq!(serde_json::to_value(&r.queue).unwrap(), queued["queue"]);
    assert_eq!(r.host_id.as_deref(), Some("h1"));
    assert_eq!(r.host_name.as_deref(), Some("Host"));
    assert_eq!(r.guild_id.as_deref(), Some("g1"));
    assert_eq!(r.voice_channel_id.as_deref(), Some("v1"));
    assert_eq!(r.member_count(), 0);
}

#[tokio::test]
async fn failed_database_open_keeps_room_serving_degraded() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("missing").join("wt.db");
    let server =
        Server::start_with_state(AppState::open_or_degraded(&path, Limits::default())).await;
    let info = server.create_room().await;
    let (mut client, _) = server.join("alice", &info).await;
    client.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(client.next("state").await["rev"], 1);
    assert!(server.room(&info.room_id).lock().unwrap().degraded);
}

#[tokio::test]
async fn write_failure_marks_room_degraded_without_rejecting_intents() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("wt.db");
    let server = Server::start_with_state(open(&path, Limits::default())).await;
    let info = server.create_room().await;
    let (mut client, _) = server.join("alice", &info).await;
    Connection::open(&path)
        .unwrap()
        .execute_batch("DROP TABLE rooms")
        .unwrap();
    client.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(client.next("state").await["rev"], 1);
    assert!(server.room(&info.room_id).lock().unwrap().degraded);
}

#[test]
fn invalid_json_room_is_skipped_and_other_rooms_load() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("wt.db");
    let store = Store::open(&path).unwrap();
    let mut good = wt_server::room::Room::new("good".into());
    good.expires_ms = now_ms() + 60_000;
    store.save(&good).unwrap();
    good.id = "bad".into();
    store.save(&good).unwrap();
    Connection::open(&path)
        .unwrap()
        .execute("UPDATE rooms SET queue_json='oops' WHERE id='bad'", [])
        .unwrap();
    let state = open(&path, Limits::default());
    assert!(state.room("good").is_some());
    assert!(state.room("bad").is_none());
}

#[tokio::test]
async fn expiry_on_boot_and_sweep_closes_sockets() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("wt.db");
    let server = Server::start_with_state(open(&path, Limits::default())).await;
    let info = server.create_room().await;
    let db = Connection::open(&path).unwrap();
    db.execute("UPDATE rooms SET expires_ms=0 WHERE id=?1", [&info.room_id])
        .unwrap();
    drop(server);
    let state = open(&path, Limits::default());
    assert!(state.room(&info.room_id).is_none());
    assert!(!Store::open(&path).unwrap().exists(&info.room_id).unwrap());

    let server = Server::start_with_state(state).await;
    let info = server.create_room().await;
    let (mut ws, _) = connect_async(server.ws_url(&info.room_id, &info.join_token))
        .await
        .unwrap();
    server.wait_for_clients(&info.room_id, 1).await;
    server.room(&info.room_id).lock().unwrap().expires_ms = 0;
    server.state.sweep(now_ms());
    let close = timeout(Duration::from_secs(1), async {
        loop {
            if let Some(Ok(Message::Close(frame))) = ws.next().await {
                break frame.unwrap();
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(u16::from(close.code), 4006);
    assert!(server.state.room(&info.room_id).is_none());
    assert!(!Store::open(&path).unwrap().exists(&info.room_id).unwrap());
}

#[tokio::test]
async fn room_cap_and_per_ip_token_bucket() {
    let dir = tempdir().unwrap();
    let state = open(
        &dir.path().join("wt.db"),
        Limits {
            max_rooms: 2,
            ..Limits::default()
        },
    );
    let server = Server::start_with_state(state).await;
    server.create_room().await;
    server.create_room().await;
    let (status, _, body) = server.http(Method::POST, "/rooms").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({"error":"room_limit"})
    );

    let server = Server::start().await;
    for _ in 0..5 {
        server.create_room().await;
    }
    let (status, _, body) = server.http(Method::POST, "/rooms").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({"error":"rate_limited"})
    );
}

#[tokio::test]
async fn member_and_queue_caps_refuse_only_new_entries() {
    let server = Server::start_with_state(AppState::open_or_degraded(
        Path::new(":memory:"),
        Limits {
            max_members: 1,
            ..Limits::default()
        },
    ))
    .await;
    let info = server.create_room().await;
    let (mut alice, _) = server.join("alice", &info).await;
    let (_alice2, welcome) = server.join("alice", &info).await;
    assert_eq!(presence_ids(&welcome), ["alice"]);
    let (mut bob, _) = connect_async(server.ws_url(&info.room_id, &info.join_token))
        .await
        .unwrap();
    let hello = json!({"v":1,"t":"hello","room":info.room_id,"seq":0,"ts":now_ms(),"from":"bob",
        "proto":1,"client":{"id":"bob","name":"bob","ver":"test"}});
    bob.send(Message::text(hello.to_string())).await.unwrap();
    let frame = timeout(Duration::from_secs(1), async {
        loop {
            if let Some(Ok(Message::Close(frame))) = bob.next().await {
                break frame.unwrap();
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(u16::from(frame.code), 4003);
    assert_eq!(frame.reason, "room full");
    alice.sync().await;
    assert_eq!(server.room(&info.room_id).lock().unwrap().member_count(), 1);
    for _ in 0..200 {
        alice.intent("queue_add", json!({"item_ref": SONG})).await;
        alice.next("state").await;
    }
    alice
        .send(
            "intent",
            json!({"op":"queue_add","args":{"item_ref":SONG},"id":"over"}),
        )
        .await;
    let rejected = alice.next("reject").await;
    assert_eq!(rejected["code"], "limit");
    assert_eq!(rejected["req_id"], "over");
    assert_eq!(server.room(&info.room_id).lock().unwrap().queue.len(), 200);
}

#[test]
fn migrations_are_idempotent() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("empty.db");
    std::fs::File::create(&path).unwrap();
    Store::open(&path).unwrap();
    Store::open(&path).unwrap();
    let db = Connection::open(path).unwrap();
    let version: i64 = db
        .pragma_query_value(None, "user_version", |r| r.get(0))
        .unwrap();
    assert_eq!(version, 1);
    for name in ["rooms", "members", "reports"] {
        let count: i64 = db
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
                [name],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }
}
