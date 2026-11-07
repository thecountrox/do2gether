# watch-together

Watch, listen and play together. One room, two modes, Discord as the lobby.

Status: **M1 server slice complete** — room server, protocol v1, clock exchange, playback anchors, queue, presence, telemetry. 15 tests green.

## Layout

```
docs/        decisions and spec
protocol/    room.schema.json — canonical wire format
server/      TypeScript room server (Node 24, ws)
app/         Flutter client (not started)
ext/         browser extension for YouTube / YTM (not started)
```

## Run

```bash
cd server
npm install
npm test          # 15 tests, ~1.5 s
npx tsc --noEmit
npm run dev       # listens on :8787
```

```
POST /rooms          -> {"room_id":"…","join_token":"…"}
GET  /health         -> {"ok":true}
WS   /ws?room=…&token=…
```

## What works

- Create room, mint a 10-minute HMAC join token, reject bad/expired tokens.
- `hello` → `welcome` snapshot (rev, playback, queue, presence) + `server_now`.
- Four-timestamp clock exchange, offset math tested to ±50 ms on one machine.
- Playback as an anchor: play/pause/seek/queue/skip, monotonic `rev` and `seq`, state broadcast.
- Reconnect receives the current anchor; reports are stored and never broadcast.
- Malformed or unknown messages are ignored without dropping the connection.

## Next

- Server v1.1: `reject` for refused intents, presence keyed by user (see `docs/02-decisions.md`).
- Discord bot: OAuth, join tokens, voice-state gating, now-playing card.
- mpv CLI client (desktop proof of sync before Flutter).
- Navidrome adapter.
- Extension scaffold for YouTube, then the YTM spike.

## Design dialogue

The architecture was stress-tested with Claude Opus 5.5; the transcript and decision table live in `~/hermes_message_home/watch-together-design/dialogue-2026-11-07.md`.
