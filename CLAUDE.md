# watch-together

One room, two modes. See `docs/00-spec.md` (owner decisions) and `protocol/room.schema.json` (wire format, canonical).

## Layout

- `protocol/` — JSON Schema for every message. Canonical. Change this first, code second.
- `server/` — TypeScript room server (Node 24, ESM, `ws`). This is the current milestone.
- `app/` — Flutter client (later).
- `ext/` — TypeScript browser extension for web sources (later).

## Server conventions

- Node 24, ESM (`"type": "module"`), TypeScript strict.
- Dependencies: `ws` only. Everything else from `node:*` (http, crypto, test, assert).
- No frameworks (no express, no fastify, no socket.io).
- Files small and single-purpose: `index.ts` (bootstrap), `room.ts` (state machine), `clock.ts` (server time), `tokens.ts` (HMAC join tokens).
- Functions over classes; no `any`; explicit return types on exported functions.
- Tests with `node:test` + `node:assert/strict` in `test/`. The test file starts the server on port 0 and uses real WebSocket clients.
- `npm test` must be green before any task is reported done.

## Protocol rules

- Every outbound message validates against `protocol/room.schema.json`.
- Server increments `rev` on every state change; `seq` is monotonic per room.
- Playback is an anchor, never a command: `{item_ref, anchor_server_ms, position_ms, rate, paused}`.
- Unknown message types are ignored, never fatal.
- Auth: HMAC-SHA256 join token, 10 minute TTL, secret from `WT_SECRET` (dev fallback allowed).

## Scope discipline

- Do not touch `app/` or `ext/` in this milestone.
- Do not add features absent from TASK.md, even obvious ones. Report them as follow-ups instead.
- No content distribution, no voice, no chat.
