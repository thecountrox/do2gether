# TASK: port the room server to Rust (parity)

Create a Cargo workspace at `rust/` that implements the same behaviour as `server/` (TypeScript reference). The wire format is fixed by `protocol/room.schema.json` and `docs/01-protocol.md`; `docs/02-decisions.md` settles rev/seq, rejects and presence identity.

## Workspace

```
rust/
  Cargo.toml                 workspace: members = ["crates/protocol", "crates/server"]
  crates/protocol/           wt-protocol — serde types, item_ref parsing, position math. No I/O.
  crates/server/             wt-server — axum + tokio, binary `wt-server`.
```

Dependencies: `axum` (with `ws`), `tokio`, `serde`, `serde_json`, `hmac`, `sha2`, `base64`, `rand`, `thiserror`. Dev: `tokio-tungstenite`, `reqwest` (or `hyper` client) for HTTP calls. Nothing else without a reason.

## Behaviour (parity with the TypeScript server)

- `POST /rooms` → `201 {"room_id":"<8 base36 chars>","join_token":"…"}`; `GET /health` → `{"ok":true}`; everything else 404.
- Token: HMAC-SHA256 over `room:exp_ms`, secret `WT_SECRET` or `dev-secret`, payload `{"room","exp"}` base64url, format `<payload>.<sig>`, TTL 10 min, constant-time compare.
- WS `/ws?room=&token=`: close 4001 invalid token, 4004 unknown room. Same parameter names.
- `hello` → `welcome {snapshot:{rev,playback,queue,presence}, server_now}`; broadcast presence join to others.
- `clock_ping` → `clock_pong` with `t1` (receive) and `t2` (send) in server ms.
- Intents: `play`, `pause`, `seek`, `queue_add`, `queue_remove`, `skip` with the same semantics as `server/src/room.ts` — read it first.
- `rev` increments only on playback/queue change; `seq` increments on every broadcast. Presence does not bump `rev`.
- Refused intent → `reject {code:"intent_rejected", message, req_id?}` to the sender and no state broadcast (this is a deltas vs the TS server; implement it here).
- `report` stored per connection, never broadcast.
- Presence keyed by `user_id`: second connection increments a count, no duplicate join, leave only when the last connection closes.
- Malformed JSON, non-v1 envelopes, unknown `t`, unknown ops: log to stderr, ignore, keep the connection.

## Tests (`cargo test`)

Port AC1–AC10 from `server/test/room.test.ts` plus: health/404, malformed input, room isolation, queue ops, and reject-on-refused-intent. Use `tokio-tungstenite` clients against a server bound to port 0. Tests must not depend on wall-clock tolerances tighter than the TS ones.

## Done means

`cargo test` green, `cargo clippy --all-targets -- -D warnings` clean, `cargo fmt --check` clean, and `rust/README.md` with run instructions. Report test count, anything the TS reference does that the Rust one deliberately does differently, and the binary size of a debug build.

## Build constraints for this host

Debug builds only; do not enable LTO or `--release` in tests. Keep the dependency tree small. If a build hangs over 5 minutes, stop and report what was compiling.
