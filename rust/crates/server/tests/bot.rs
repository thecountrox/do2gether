#[allow(dead_code)]
mod support;

use std::time::Duration;

use futures_util::StreamExt;
use hyper::{Method, StatusCode};
use rusqlite::Connection;
use serde_json::{Value, json};
use support::*;
use tempfile::tempdir;
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use wt_server::{AppState, Limits, tokens::verify_token};

async fn request(
    server: &Server,
    method: Method,
    path: &str,
    body: Value,
    token: Option<&str>,
) -> (StatusCode, Value) {
    let (status, _, bytes) = server
        .http_auth(method, path, body.to_string().into(), token)
        .await;
    (
        status,
        if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap()
        },
    )
}

#[tokio::test]
async fn bot_auth_snapshot_and_tokens() {
    let disabled = Server::start_with_state(AppState::default().with_bot_token(None)).await;
    let room = disabled.create_room().await;
    for method in [Method::PATCH, Method::DELETE] {
        assert_eq!(
            request(
                &disabled,
                method,
                &format!("/rooms/{}", room.room_id),
                json!({}),
                Some("bot")
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    assert_eq!(
        request(
            &disabled,
            Method::POST,
            &format!("/rooms/{}/tokens", room.room_id),
            json!({}),
            Some("bot")
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );

    let server =
        Server::start_with_state(AppState::default().with_bot_token(Some("bot".into()))).await;
    let room = server.create_room().await;
    let path = format!("/rooms/{}", room.room_id);
    let token_path = format!("{path}/tokens");
    let (mut host, _) = server.join("alice", &room).await;
    host.intent("play", json!({"item_ref": FILM})).await;
    host.next("state").await;
    let (status, snapshot) = request(&server, Method::GET, &path, json!({}), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        snapshot["members"],
        json!([{"user_id":"alice","name":"alice"}])
    );
    assert_eq!(snapshot["playback"]["item_ref"], FILM);
    assert_eq!(snapshot["host_id"], "alice");
    assert!(snapshot.get("join_token").is_none());
    for token in [None, Some("wrong")] {
        assert_eq!(
            request(
                &server,
                Method::POST,
                &token_path,
                json!({"user_id":"bob","user_name":"Bob"}),
                token
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
    }
    let (status, minted) = request(
        &server,
        Method::POST,
        &token_path,
        json!({"user_id":"bob","user_name":"Bob"}),
        Some("bot"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(minted["expires_in_ms"], 600_000);
    assert!(verify_token(
        minted["join_token"].as_str().unwrap(),
        &room.room_id
    ));
    assert_eq!(
        request(
            &server,
            Method::PATCH,
            &path,
            json!({"locked":true,"controls":"all"}),
            Some("wrong")
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (status, patched) = request(
        &server,
        Method::PATCH,
        &path,
        json!({"locked":true,"controls":"all"}),
        Some("bot"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(patched["rev"], 2);
    assert_eq!(patched["controls"], "all");
    assert_eq!(host.next("state").await["meta"]["locked"], true);
    assert_eq!(
        server
            .connect_expecting_close(&room.room_id, &room.join_token)
            .await
            .0,
        4003
    );
    assert_eq!(
        request(
            &server,
            Method::POST,
            &token_path,
            json!({"user_id":"bob","user_name":"Bob"}),
            Some("bot")
        )
        .await,
        (StatusCode::CONFLICT, json!({"error":"room_locked"}))
    );
    assert_eq!(
        request(&server, Method::DELETE, &path, json!({}), Some("wrong"))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(&server, Method::DELETE, &path, json!({}), Some("bot"))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        request(&server, Method::GET, &path, json!({}), None)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn full_room_and_delete_closes_active_socket() {
    let state = AppState::open_or_degraded(
        std::path::Path::new(":memory:"),
        Limits {
            max_members: 1,
            ..Limits::default()
        },
    )
    .with_bot_token(Some("bot".into()));
    let server = Server::start_with_state(state).await;
    let room = server.create_room().await;
    let (mut ws, _) = connect_async(server.ws_url(&room.room_id, &room.join_token))
        .await
        .unwrap();
    let hello = json!({"v":1,"t":"hello","room":room.room_id,"seq":0,"ts":now_ms(),"from":"alice","proto":1,"client":{"id":"alice","name":"alice","ver":"test"}});
    use futures_util::SinkExt;
    ws.send(Message::text(hello.to_string())).await.unwrap();
    assert!(matches!(
        ws.next().await.unwrap().unwrap(),
        Message::Text(_)
    ));
    let path = format!("/rooms/{}", room.room_id);
    assert_eq!(
        request(
            &server,
            Method::POST,
            &format!("{path}/tokens"),
            json!({"user_id":"bob","user_name":"Bob"}),
            Some("bot")
        )
        .await,
        (StatusCode::CONFLICT, json!({"error":"room_full"}))
    );
    assert_eq!(
        request(&server, Method::DELETE, &path, json!({}), Some("bot"))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    let frame = timeout(Duration::from_secs(1), async {
        loop {
            if let Some(Ok(Message::Close(frame))) = ws.next().await {
                break frame.unwrap();
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(u16::from(frame.code), 4006);
}

#[tokio::test]
async fn deleted_room_is_removed_from_database() {
    let dir = tempdir().unwrap();
    let db = dir.path().join("rooms.db");
    let state = AppState::open(&db, Limits::default())
        .unwrap()
        .with_bot_token(Some("bot".into()));
    let server = Server::start_with_state(state).await;
    let room = server.create_room().await;
    let path = format!("/rooms/{}", room.room_id);
    assert_eq!(
        request(&server, Method::DELETE, &path, json!({}), Some("bot"))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    let count: i64 = Connection::open(db)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM rooms WHERE id=?1",
            [&room.room_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn metrics_and_stats_reflect_intents_reports_and_degraded_db() {
    let server = Server::start().await;
    let room = server.create_room().await;
    let (mut host, _) = server.join("alice", &room).await;
    let (mut guest, _) = server.join("bob", &room).await;
    guest.intent("play", json!({"item_ref": FILM})).await;
    assert_eq!(guest.next("reject").await["code"], "not_host");
    host.intent("play", json!({"item_ref": FILM})).await;
    host.next("state").await;
    for drift in [12.4, 88.0] {
        host.send(
            "report",
            json!({"observed":{"offset_ms":0,"rtt_ms":1,"drift_ms":drift,"source":"mpv"}}),
        )
        .await;
    }
    host.sync().await;
    let (status, _, bytes) = server.http(Method::GET, "/metrics").await;
    assert_eq!(status, StatusCode::OK);
    let metrics = String::from_utf8(bytes.to_vec()).unwrap();
    for line in [
        "wt_rooms 1",
        "wt_clients 2",
        "wt_intents_total{op=\"play\",result=\"ok\"} 1",
        "wt_intents_total{op=\"play\",result=\"reject\"} 1",
        "wt_rejects_total{code=\"not_host\"} 1",
        "wt_db_degraded 0",
    ] {
        assert!(metrics.contains(line), "missing {line}: {metrics}");
    }
    assert!(metrics.contains(&format!("wt_room_members{{room=\"{}\"}} 2", room.room_id)));
    assert!(metrics.contains(&format!(
        "wt_drift_ms{{room=\"{}\",quantile=\"0.95\"}} 88",
        room.room_id
    )));
    let (_, _, bytes) = server.http(Method::GET, "/stats").await;
    let stats: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        stats["totals"],
        json!({"rooms":1,"clients":2,"intents":2,"rejects":1})
    );
    assert_eq!(stats["rooms"][0]["corrections"], 1);
    assert_eq!(stats["rooms"][0]["p95_drift_ms"], 88.0);
    assert_eq!(stats["rooms"][0]["members"], 2);
}
