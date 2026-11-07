# Backend architecture (target)

Status: v1 is a single Rust binary, rooms in memory. This is the shape it grows into without a rewrite.

## Process shape

```
wt-server
├── HTTP (axum)          /health /rooms /rooms/{id} /metrics /stats
├── WS   (axum)          /ws?room&token
├── RoomTable            RwLock<HashMap<RoomId, Arc<Mutex<Room>>>>
├── Store                SQLite (WAL), write-through, loaded at boot
└── Sweeper              TTL + limits, one task, every 60 s
```

One process, one database file, no external services. That is deliberate: a friends-scale room
server that needs Redis to start is a worse product. Horizontal scale is a later, separate decision
(sticky rooms + Redis pub/sub), and the protocol already survives it because clients reconnect and
re-snapshot.

## Concurrency model

- `RoomTable` is an `RwLock<HashMap<..>>`; readers clone the `Arc`, then take the room mutex.
- Every WS connection owns its `Client`; intents take the room mutex, mutate, bump `rev`, then
  broadcast outside the lock.
- One room's intents serialize; different rooms never contend. This is the room-actor model with a
  mutex instead of a mailbox — adequate until a room needs async work inside an intent (nothing does
  today).

## Persistence

SQLite, WAL, `rusqlite` (bundled). Memory is authoritative; the database is durability, not the
source of truth during a run.

```
rooms(id, created_ms, host_id, host_name, guild_id, voice_channel_id,
      controls, locked, rev, seq, playback_json, queue_json, expires_ms)
members(room_id, user_id, name, joined_ms, PRIMARY KEY(room_id, user_id))
reports(room_id, user_id, received_ms, offset_ms, rtt_ms, drift_ms, source)
```

- Write-through on every `rev` change and on presence join/leave, inside the same lock that mutated
  the room, so the database never trails a broadcast.
- Boot: create schema if missing (`PRAGMA user_version` migrations), load rooms into memory.
- A write failure logs and sets a room `degraded` flag; the room keeps serving. It does not reject
  playback because the disk hiccuped.
- Reports are capped: one row per (room, user), overwritten; drift stats live in memory, not SQL.

## Lifecycle and limits

- Room TTL: 24 h after last activity, swept every 60 s. Expired rooms are deleted from memory and DB.
- Max rooms: 500. Max members per room: 50. Max queue items: 200.
- `POST /rooms` rate limit: 5 per minute per IP (in-memory token bucket, trusted-proxy aware).
- Finished/empty rooms are not deleted immediately: a room with zero members but recent activity
  stays joinable for the TTL, so a reconnect after a crash works.

## Identity and permissions

- **Join tokens** remain the only way into a WS. Minted by `POST /rooms` (host) or
  `POST /rooms/{id}/tokens` (bot). 10 min TTL, HMAC.
- **Host** is the creator (`host_id`). `controls` is `host` (default) or `all`:
  - `host`: `play`, `pause`, `seek`, `skip`, `set_controls`, `kick`, `lock` are host-only.
  - `all`: playback is open; `set_controls`, `kick`, `lock` stay host-only.
  - `queue_add` / `queue_remove` are open in both modes — DJ mode depends on it.
- A refused intent gets `reject {code:"not_host" | "locked" | "limit" | "intent_rejected"}`.
- `locked` rooms reject new WS joins with close 4003.
- Kick closes the target socket with 4005 and drops their presence.

## Bot API (server-to-server)

Authenticated with `Authorization: Bearer $WT_BOT_TOKEN`; disabled (404) when the env var is unset.

| Method | Path | Purpose |
|---|---|---|
| POST | `/rooms` | create; body may carry `{host_id, host_name, guild_id, voice_channel_id}` |
| GET | `/rooms/{id}` | public snapshot for embeds: room id, host, members, playback summary, rev |
| POST | `/rooms/{id}/tokens` | mint a join token for `{user_id, user_name}`; enforces limits and lock |
| PATCH | `/rooms/{id}` | `{locked, controls}` — host/bot only |
| DELETE | `/rooms/{id}` | close and delete |

The room server never talks to Discord. The bot owns OAuth, voice-state checks and permissions;
by the time it calls `/tokens`, the decision is already made. That keeps this service testable with
curl and keeps Discord's API churn out of the core.

## Observability

- `GET /metrics` (Prometheus text): `wt_rooms`, `wt_clients`, `wt_intents_total{op,result}`,
  `wt_rejects_total{code}`, `wt_drift_ms{quantile}` per room (last 500 samples), `wt_db_degraded`.
- `GET /stats` (JSON): per-room `{rev, members, p50_drift, p95_drift, corrections}` for the Clawn
  bot's now-playing card and for tuning tolerances.
- Structured logs: one line per intent with room, actor, op, result, drift.

## Failure modes accepted

- Process restart drops live sockets; clients reconnect, rooms survive via SQLite.
- Disk full: degraded mode, rooms keep running, writes dropped with an error log.
- Clock skew between clients is the client's problem; server time is the only reference.
- No horizontal scale, no Redis, no sharding. If rooms ever exceed one node, that is a new design,
  not a flag.

## Non-goals for this milestone

- Discord OAuth inside the room server (bot's job).
- Media storage or streaming (host-streamed Navidrome comes later, as its own service contract).
- Game transports (input clock) — protocol reserves the delivery class, nothing implements it yet.
