# TASK: room permissions, host controls, meta in the snapshot

Depends on TASK6 (persistence) being in place. Read `docs/05-backend-architecture.md` §Identity and permissions.

## Room fields

Add to `Room` and the DB row: `host_id`, `host_name` (set at creation from the `POST /rooms` body),
`controls` (`"host"` default, or `"all"`), `locked` (bool, default false).

`POST /rooms` body becomes `{host_id?, host_name?, guild_id?, voice_channel_id?}`; if `host_id` is
missing, generate one and return it in the 201 response as `host_id` so clients can identify the host.

## Protocol addition (update the schema and both type layers)

`welcome.snapshot.meta`:

```json
{ "host_id": "…", "host_name": "…", "controls": "host", "locked": false }
```

Optional for older clients; the server always sends it. Update `protocol/room.schema.json`, the Rust
`wt-protocol` types, and the Flutter `protocol.dart` (`Snapshot.meta`), plus their tests.

## Intents

| op | who | args |
|---|---|---|
| `play`, `pause`, `seek`, `skip` | host when `controls=host`; anyone when `all` | as today |
| `queue_add`, `queue_remove` | anyone | as today |
| `set_controls` | host always | `{controls:"host"\|"all"}` |
| `lock` | host always | `{locked:true\|false}` |
| `kick` | host always | `{user_id}` |

- Refusals: `reject {code:"not_host"}`, `{code:"locked"}` (intent on a locked room other than `lock`),
  `{code:"limit"}` (queue cap), `{code:"intent_rejected"}` (bad args/state).
- A locked room accepts no new WS joins: close 4001 still applies to bad tokens; a valid token on a
  locked room closes 4003 `room locked`.
- `kick` closes the target connection with 4005 `kicked` and removes presence. Host cannot kick self.
- Broadcast a `state` on `set_controls`/`lock` (rev bumps, since meta is room state); `kick` is
  presence-only plus a `reject`-free close.

## Tests

1. Join with a non-host identity and `controls=host`: `play` → `reject not_host`; `queue_add` works.
2. Host sets `controls=all`: a guest `play` then succeeds; `lock` still refused for the guest.
3. `lock` closes new joins with 4003, and the host can still control.
4. `kick` closes the target with 4005 and removes presence; host kicking self → `intent_rejected`.
5. `meta` appears in `welcome` and changes after `set_controls`/`lock`.
6. Existing tests updated for the new snapshot field; schema validation passes.

## Done means

`cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, Flutter
`flutter analyze && flutter test` green, and a report of the permission matrix as implemented.
