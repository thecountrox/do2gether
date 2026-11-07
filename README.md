# watch-together

Watch, listen and play together. One room, two modes, Discord as the lobby.

**v0 is live:** Rust room server deployed at `https://watch.141.253.97.15.sslip.io`, and `wt-play` — a real mpv client that joins a room, syncs to the room anchor, and reports drift. Measured over the public wss endpoint on one machine: **max 120 ms, p95 119 ms** after play, seek and pause.

**v1 client:** `app/` is a Flutter desktop client — join screen, `Create room`, presence, clock,
`media_kit` player keyed by the same `item_ref`, drift correction and telemetry. `flutter analyze`,
26 tests and `flutter build linux --debug` are green; the bundle launches under Xvfb.

**Android:** the same Flutter app builds an APK on this aarch64 host (SDK tools run through qemu):
`app-arm64-v8a-debug.apk`, 95 MB, minSdk 24, target 36, `libmpv.so` bundled.
Download: https://files.141.253.97.15.sslip.io/user_uploads/watch-together/app-arm64-v8a-debug.apk
Build recipe and limitations: `docs/04-android.md`. Release AOT builds are blocked by the nix SDK
(no Android `gen_snapshot` for linux-arm64); debug APKs are functional.

## Layout

```
docs/        spec, protocol notes, decisions, stack
protocol/    room.schema.json — canonical wire format
rust/        wt-protocol, wt-server, wt-cli (wt-play)   <- production code
server/      TypeScript reference implementation (kept until parity is signed off)
app/         Flutter client (v1, not started)
ext/         browser extension for YouTube / YTM (v1, not started)
deploy/      systemd unit, Caddy block, ops notes
scripts/     demo-local.sh — two mpv clients against a room
```

## Quick start

```bash
cd rust
cargo build --release -p wt-server -p wt-cli
cargo test                       # 44 tests

# terminal 1
WT_SECRET=dev ./target/release/wt-server

# terminal 2 — create a room and play a file
./target/release/wt-play --server http://127.0.0.1:8787 --create --file /tmp/movie.mp4

# terminal 3 — join it (copy the share line from terminal 2)
./target/release/wt-play --server http://127.0.0.1:8787 --room <id> --token <token> --file /tmp/movie.mp4
```

Against the deployed server:

```bash
./target/release/wt-play --server https://watch.141.253.97.15.sslip.io --create --file /tmp/movie.mp4
```

stdin commands in `wt-play`: `play`, `pause`, `seek <ms>`, `q`.

## What works

- Rooms, HMAC join tokens (10 min), `hello`/`welcome` snapshots, presence keyed by user.
- Bot API (`WT_BOT_TOKEN` bearer auth): `POST /rooms/{id}/tokens`, `PATCH /rooms/{id}`, `DELETE /rooms/{id}`; public `GET /rooms/{id}`, `/metrics`, and `/stats`.
- Four-timestamp clock exchange; offset ±1 ms on loopback, ±50 ms tested.
- Playback as an anchor: play/pause/seek/queue/skip with monotonic `rev`/`seq`, explicit `reject` for refused intents.
- mpv client with drift policy (ignore < 250 ms, rate 250 ms–2 s, seek > 2 s), `--hr-seek=yes`, telemetry every 5 s.
- TLS end to end (rustls, native roots), deployed behind Caddy with a real certificate.
- Two headless mpv clients converge; `scripts/demo-local.sh` reproduces it.

## Backend (v1.1)

- **SQLite persistence** (WAL): rooms, playback, queues and lock/controls survive a restart; rooms
  reload at boot, members rebuild from connections.
- **Lifecycle**: 24 h idle TTL swept every minute, max 500 rooms, 50 members/room, 200 queue items,
  5 room creations/min/IP.
- **Permissions**: `host` (default) or `all`; `play/pause/seek/skip` host-only in `host` mode,
  `queue_*` always open, `set_controls`/`lock`/`kick` host-only. Locked rooms reject joins (4003),
  kicks close 4005.
- **Bot API** (`WT_BOT_TOKEN`): `GET /rooms/{id}`, `POST /rooms/{id}/tokens`, `PATCH`, `DELETE`.
- **Observability**: `/metrics` (Prometheus) and `/stats` (JSON, p50/p95 drift per room), counters
  for intents and rejects.

Verified live on the deployed server: create with `host_id` → public snapshot → bot token → guest
`play` rejected `not_host` → `queue_add` accepted → lock → service restart → `locked=true, rev=1`.

## Known gaps

- Bot-minted join tokens are room-bound but not user-bound: the joining client claims its identity in `hello`.
- Drift after a seek settles around 100–180 ms, inside the 250 ms video tolerance but not tight enough for music (needs the host-stream model).
- No Discord bot yet — needs a bot token and the choice of separate bot vs Clawn plugin.
- Android is a debug APK, not a release build (nix SDK lacks AOT `gen_snapshot` on linux-arm64).
- TypeScript server remains as the reference; it will be deleted once the Rust one has run for a week.

## Next

- Flutter app: room list, media library, mpv texture, join from Discord.
- Discord bot: OAuth, join tokens, voice-state gating, now-playing card, control buttons.
- Navidrome adapter + host-stream mode (music done right).
- Extension scaffold for YouTube, then the YTM spike.

## Design dialogue

Architecture was stress-tested with Claude Opus 5.5; transcript and decision table in `~/hermes_message_home/watch-together-design/dialogue-2026-11-07.md`.
