# TASK: bot-facing API and observability

Depends on TASK6 (store) and TASK7 (host/controls/lock). Read `docs/05-backend-architecture.md`
§Bot API and §Observability.

## Bot auth

`WT_BOT_TOKEN` env. When unset, every `/rooms/**` bot endpoint answers 404 (disabled). When set,
`Authorization: Bearer <token>` is required (constant-time compare); wrong/missing → 401.

## Endpoints

| Method | Path | Body / response |
|---|---|---|
| POST | `/rooms` | unchanged creation + optional metadata; bot may set `host_id` |
| GET | `/rooms/{id}` | **public**, no auth: `{room_id, host_id, host_name, controls, locked, rev, members:[{user_id,name}], playback:{item_ref,position_ms,paused}\|null, created_ms, expires_ms}` |
| POST | `/rooms/{id}/tokens` | bot auth; `{user_id, user_name}` → `{join_token, room_id, expires_in_ms}`; refuses locked (409 `room_locked`) or full (409 `room_full`) |
| PATCH | `/rooms/{id}` | bot auth; `{locked?, controls?}` → 200 with meta |
| DELETE | `/rooms/{id}` | bot auth; closes sockets 4006, deletes from memory and DB → 204 |

The token minted by `/tokens` uses the same HMAC format and 10 min TTL. Tokens are not bound to the
user yet (identity is claimed in `hello`); note that in the README as a known limitation.

## Observability

`GET /metrics` — Prometheus text, no auth, no secrets:

```
wt_rooms 12
wt_clients 27
wt_intents_total{op="play",result="ok"} 41
wt_intents_total{op="play",result="reject"} 3
wt_rejects_total{code="not_host"} 2
wt_room_members{room="abc"} 4
wt_drift_ms{room="abc",quantile="0.5"} 12.4
wt_drift_ms{room="abc",quantile="0.95"} 88.0
wt_db_degraded 0
```

Drift from in-memory ring buffers: last 500 samples per room, p50/p95 computed on scrape (sort a copy;
rooms are small).

`GET /stats` — JSON, no auth: `{rooms:[{room_id, rev, members, p50_drift_ms, p95_drift_ms, corrections}], totals:{rooms, clients, intents, rejects}}`.
`corrections` = count of intents that changed playback this process (cheap counter).

Keep counters in `AppState` (`AtomicU64`), not in the DB.

## Tests

1. Bot endpoints 404 when `WT_BOT_TOKEN` unset; 401 with a wrong token; 200/201 with the right one.
2. `POST /tokens` on a locked room → 409 `room_locked`; on a full room → 409 `room_full`.
3. `GET /rooms/{id}` returns members and playback without auth, and never a token.
4. `PATCH` locks the room and the next WS join closes 4003.
5. `DELETE` closes sockets with 4006 and a later `GET` is 404.
6. `/metrics` contains the expected lines after a play and a rejected play; `/stats` matches.
7. Existing tests still pass.

## Done means

`cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, plus a report with
one real `curl` transcript for create → token → metrics.
