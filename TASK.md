# TASK: M1 room server (first slice)

Implement `server/` exactly as below. No client code, no extension, no UI.

## Files

- `server/package.json` — `"type": "module"`, scripts `dev` (tsx watch src/index.ts) and `test` (node --test --experimental-strip-types test/), deps `ws`, dev deps `typescript`, `tsx`, `@types/ws`, `@types/node`.
- `server/tsconfig.json` — NodeNext, strict, target ES2023, noEmit for typecheck.
- `server/src/index.ts` — HTTP + WS bootstrap.
- `server/src/room.ts` — room state machine.
- `server/src/clock.ts` — server time source.
- `server/src/tokens.ts` — HMAC join tokens.
- `server/test/room.test.ts` — the acceptance tests.

## HTTP

- `POST /rooms` → `201 {"room_id":"<8 chars base36>","join_token":"<token>"}`. Creates an empty room.
- `GET /health` → `200 {"ok":true}`.
- 404 otherwise. JSON bodies only where applicable.

## Join tokens

- HMAC-SHA256 over `room_id + ":" + exp_ms`, key `process.env.WT_SECRET || "dev-secret"`.
- Token format: `<base64url(payload)>.<base64url(sig)>` where payload is `{"room":"…","exp":<ms>}`.
- TTL 10 minutes. `verifyToken(token, roomId)` returns boolean; expired or wrong-room tokens fail.
- WS connect: `/ws?room=<id>&token=<token>`; invalid token → close with code 4001, no room join.

## WebSocket behaviour

- On connect, client sends `hello` (validate `proto === 1`). Server replies `welcome` with `{snapshot:{rev, playback, queue, presence}, server_now}` and broadcasts `presence join` to others.
- `clock_ping {ping_id,t0}` → `clock_pong {ping_id,t0,t1,t2}` where `t1` is receive time and `t2` send time, both server ms.
- `intent` ops:
  - `play`: playback anchor set to `{item_ref, anchor_server_ms: now, position_ms, rate:1, paused:false}`. If no current playback, `args.item_ref` required.
  - `pause`: `position_ms` computed from current anchor at `now`, `paused:true`, anchor reset to `now`.
  - `seek`: `args.position_ms`, anchor `now`, preserve item/rate/paused state.
  - `queue_add` / `queue_remove`: `args.item_ref`.
  - `skip`: pop queue head into playback, or clear playback if empty.
- Every accepted intent increments `rev`, increments `seq`, broadcasts `state {rev, playback, queue}` to the whole room.
- `report`: store latest per client in memory; never broadcast.
- Disconnect: remove presence, broadcast `presence leave`, drop reports.
- Malformed JSON or unknown `t`: ignore, log to stderr, do not crash.
- Multiple rooms are isolated.

## Acceptance tests (all must pass)

1. `POST /rooms` returns id + token; two rooms get different ids.
2. Bad token rejected (WS close 4001). Expired token rejected (freeze time or short TTL via query `?ttl=` for test only — prefer exporting `signToken(room, ttlMs)`).
3. `hello` → `welcome`; `welcome.snapshot.presence` contains the joining client after a second client joins.
4. Clock: 10 pings, median `offset = ((t1-t0)+(t2-t3))/2` within ±50 ms of zero when all timestamps come from the same machine.
5. Play propagation: client A sends `intent play`, client B receives `state` with `paused:false` and a valid `anchor_server_ms`, within 500 ms.
6. Pause: after `pause`, `position_ms` is within 100 ms of elapsed time since the play anchor.
7. Seek: `seek 42000` produces `position_ms === 42000`.
8. Rev/seq monotonicity across five intents.
9. Reconnect: a new client gets a `welcome` whose playback matches the latest state (same `item_ref`, `paused`, position within 150 ms).
10. `report` is accepted and never broadcast to another client.

## Done means

`npm install && npm test` green, `npx tsc --noEmit` clean, and a short report: files, test count, anything you deliberately left out.
