# TASK: Flutter client v0 — join a room, watch a file synced

`app/` is a Flutter project (Linux desktop) with `media_kit`, `media_kit_video`, `media_kit_libs_linux`, `file_selector`, `web_socket_channel` and `crypto` already added. Implement the client below. Do not touch `rust/` or `server/`.

## Screens

**JoinScreen**
- Fields: server URL (default `https://watch.141.253.97.15.sslip.io`), room id, token, display name (default from `Platform.localHostname`).
- `Create room` → `POST /rooms` via `dart:io HttpClient`, fills room id + token from the response.
- `Join` → validates the URL (`http`/`https`), non-empty room and token, then opens RoomScreen.

**RoomScreen**
- Connects `ws://` or `wss://` (same host/path, `/ws?room=…&token=…`).
- Sends `hello {proto:1, client:{id,name,ver}, caps:[]}`; expects `welcome`.
- Clock: 10 `clock_ping` samples, median offset and rtt, refresh every 30 s; show `offset`, `rtt`, `rev`, connection state.
- Presence list from `welcome` + `presence` messages.
- Now playing: `item_ref` and local-file match state.
- Controls: `Open file…` (file_selector), `Play`, `Pause`, `-10 s`, `+10 s`. Play/pause/seek send `intent` with a fresh `id`.
- On `state`: apply the anchor to the local player (see Player).
- On `reject`: show a snackbar with the message.

## Player

- `media_kit` `Player` + `VideoController`; `MediaKit.ensureInitialized()` in `main()`.
- Opening a file computes `item_ref = file:sha256p:<size>:<first32hex>:<last32hex>` — SHA-256 of the first 4 MiB and of the last 4 MiB (for files < 8 MiB, hash the whole file twice; keep the hex lowercase 32 chars).
- Apply anchor: if `item_ref` differs from the local file → show "waiting for host file", do nothing. Same file:
  - `paused` → pause and seek to `position_ms`.
  - playing: compute current position from the player and target from the anchor using the clock; drift < 250 ms → nothing; 250 ms–2 s → set `player.setRate(1 ± 0.03)` for up to 2 s; > 2 s → `player.seek`.
- Poll position every 1 s; display drift; send `report {activity_id:null, observed:{offset_ms,rtt_ms,drift_ms,source:"flutter"}}` every 5 s.
- On leaving the screen: dispose the player and close the socket.

## Protocol module

`lib/protocol.dart`: envelope encode/decode (`{v,t,room,seq,ts,from,id?}`), message models for the ten types in `protocol/room.schema.json`, `positionAt(playback, serverNowMs)`, item_ref validation for the four prefixes. Invalid/unknown messages are ignored, never crash.

## Style

Material 3, dark theme, `setState` only, no state-management package. Small files: `main.dart`, `protocol.dart`, `clock.dart`, `room_client.dart`, `join_screen.dart`, `room_screen.dart`, `player.dart`.

## Tests (no display needed)

- protocol: envelope roundtrip, unknown type ignored, item_ref grammar accept/reject.
- clock: median offset with synthetic samples, outlier rejection.
- player: `positionAt` cases (playing/paused/rate/negative elapsed); item_ref hash on a small temp file.
- widget: JoinScreen rejects an empty room and a bad URL.

## Done means

```
nix shell nixpkgs#flutter -c bash -c 'cd app && flutter analyze && flutter test && flutter build linux --debug'
```

clean, plus `app/README.md` (run, join, limitations). Report files, test count, build output path, and anything deliberately deferred.
