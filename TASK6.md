# TASK: persistence, lifecycle and limits

Follow `docs/05-backend-architecture.md`. Keep the WS protocol and `protocol/room.schema.json` unchanged in this task; this is storage, lifecycle and abuse limits only.

## Store

- Add `rusqlite` with the `bundled` feature.
- `WT_DB` env: path (default `wt.db`). Tests use a temp file.
- Migrations via `PRAGMA user_version`; schema in the architecture doc (`rooms`, `members`, `reports`).
- WAL mode, `synchronous=NORMAL`, foreign keys on.
- Load all rooms at boot into `RoomTable`; a room row whose JSON fails to parse is logged and skipped, not fatal.
- Write-through: every `rev` change, every presence join/leave, and room creation updates the DB **inside the same critical section** that mutates the room, before the broadcast.
- A DB error logs, marks the room `degraded` (in memory), and continues. Do not fail the intent.
- On boot, delete rows whose `expires_ms < now`.

## Lifecycle

- Room TTL: 24 h after last activity (`WT_ROOM_TTL_HOURS` override). Activity = any accepted intent or presence change.
- Sweeper task every 60 s: expire rooms, drop from memory and DB, close their sockets with 4006.
- Zero-member rooms stay until TTL (reconnect story).
- `POST /rooms` stays `201 {room_id, join_token}` and accepts an optional JSON body:
  `{host_id, host_name, guild_id, voice_channel_id}` — all optional strings. Store them; include
  `host_id`/`host_name` in the room, used by later tasks.

## Limits

- Max rooms: 500 (`WT_MAX_ROOMS`). Over → `503 {"error":"room_limit"}`.
- Max members per room: 50 (`WT_MAX_MEMBERS`). Join over → WS close 4003 with reason `room full`.
- Max queue items: 200. `queue_add` over → `reject {code:"limit"}`.
- `POST /rooms` rate limit: 5/min per client IP, in-memory token bucket. Over → `429 {"error":"rate_limited"}`.
  Use `ConnectInfo<SocketAddr>`; do not trust `X-Forwarded-For` until a trusted-proxy config exists.

## Tests (add to the existing suite)

1. Persistence: create room, play, add queue, drop the server, reopen the same DB, the room is back
   with the same `rev`, playback and queue.
2. DB failure is non-fatal: point `WT_DB` at a read-only directory; room still serves intents
   (degraded flag set, logged).
3. TTL: a room with `expires_ms` in the past is not loaded at boot and is swept.
4. Limits: room cap, member cap, queue cap, rate limit (sixth create in a minute → 429).
5. Migration: opening an empty file creates the schema; opening twice is idempotent.
6. Existing 44 tests still pass.

## Done means

`cargo test` green, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, and a short
report: schema, env vars, test count, and anything the architecture doc asked for that you skipped.
