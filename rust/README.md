# watch-together room server (Rust)

Rust port of `server/` (TypeScript reference). Wire format: `protocol/room.schema.json` and
`docs/01-protocol.md`; rev/seq, rejects and presence identity follow `docs/02-decisions.md`.

```
rust/
  Cargo.toml          workspace
  crates/protocol/    wt-protocol: message types, item_ref parsing, position math (no I/O)
  crates/server/      wt-server: axum + tokio, binary `wt-server`
```

## Requirements

Rust 1.88+ (edition 2024, let-chains); developed on 1.99. `cargo clippy` and `cargo fmt` need
the clippy and rustfmt components. On a Nix setup without them:
`nix shell nixpkgs#clippy nixpkgs#rustfmt`.

## Run

```sh
cd rust
cargo run -p wt-server                          # listens on 0.0.0.0:8787
PORT=9000 WT_SECRET=change-me cargo run -p wt-server
```

| Variable    | Default      | Meaning                                                   |
|-------------|--------------|-----------------------------------------------------------|
| `PORT`      | `8787`       | TCP port (`0` picks a free one; the bound port is printed) |
| `BIND`      | `0.0.0.0`    | Interface to bind; production uses `127.0.0.1` behind Caddy |
| `WT_SECRET` | `dev-secret` | HMAC key for join tokens (empty counts as unset)          |

Rooms live in memory only and disappear when the process exits.

```sh
curl -X POST localhost:8787/rooms     # 201 {"room_id":"k3x9a0qz","join_token":"..."}
curl localhost:8787/health            # {"ok":true}
# WebSocket: ws://localhost:8787/ws?room=<room_id>&token=<join_token>
#   close 4001 = invalid/expired token, 4004 = unknown room
```

## wt-play (mpv client)

```sh
cargo run -p wt-cli -- --server http://127.0.0.1:8787 --create --file /tmp/movie.mp4
cargo run -p wt-cli -- --server https://watch.141.253.97.15.sslip.io \
  --room <id> --token <token> --file /tmp/movie.mp4
```

Flags: `--create`, `--room/--token`, `--file`, `--name`, `--mpv`, `--headless` (`--vo=null --ao=null`), `--simulate`
(wall-clock virtual player for tests). stdin: `play`, `pause`, `seek <ms>`, `q`.

- TLS (rustls, native roots) is supported for both `https://` create and `wss://` join.
- mpv runs with `--hr-seek=yes`; without it a seek lands on a keyframe and parks the drift at
  175–215 ms, just under the 250 ms ignore threshold, so it is never corrected.
- Drift policy: ignore < 250 ms, rate ±3 % between 250 ms and 2 s, seek beyond 2 s.


## Test and lint

```sh
cargo test                                   # 30 tests: 11 unit + 19 integration
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

The integration tests (`crates/server/tests/room.rs`) start a server on port 0 per test and drive
it with real `tokio-tungstenite` clients. Every message, inbound and outbound, is validated against
`protocol/room.schema.json`.

## Debug build size

`target/debug/wt-server`: 29,842,344 bytes (about 28.5 MiB, unoptimized with debuginfo; aarch64-linux, rustc 1.99).

## Differences from the TypeScript server

These are deliberate, following `TASK2.md` and `docs/02-decisions.md`:

- **Refused intents.** The sender gets `reject {code:"intent_rejected", message, req_id?}`, where `req_id` echoes the intent's `id`. There is no broadcast, and neither `rev` nor `seq` changes. TS stays silent.
- **`seq` and presence.** `seq` increments on every broadcast, presence join/leave included; TS bumps it only for `state`. `rev` still changes only with playback/queue. A joiner's `welcome` is sent after its own join is sequenced, so the snapshot's `seq` covers every event it reflects.
- **Presence identity.** Presence is keyed by `user_id` with a connection count. A user's second connection produces no `join`, the snapshot lists each user once, and `leave` is sent only when the user's last connection closes.
