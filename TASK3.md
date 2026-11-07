# TASK: `wt-play` — mpv client (v0 end to end)

Add `rust/crates/cli` (binary `wt-play`) to the workspace. It joins a room, drives a real mpv process over JSON IPC, and keeps its playhead matched to the room anchor. This is the proof that two people can watch together before any Flutter UI exists.

## Flags

```
--server <url>      default http://127.0.0.1:8787
--room <id>         join an existing room
--token <token>     join token for --room
--create            POST /rooms, then join it (prints room id + share line)
--file <path>       media file (required unless --simulate)
--name <name>       display name (default: hostname)
--mpv <path>        default "mpv"
--headless          pass --vo=null --ao=null --no-terminal to mpv (CI)
--simulate          virtual player (wall clock) instead of mpv; used by tests
```

## Behaviour

- Clock: 10 `clock_ping` samples, median offset; refresh every 30 s. All scheduling uses `server_now()`, never local wall time.
- On `welcome`: if playback exists, load the file, seek to the anchored position, and honour `paused`.
- On `state`: apply the anchor. Drift policy: < 250 ms do nothing; 250 ms–2 s set mpv `speed` to 1.0 ± 0.03 for up to 2 s then back to 1.0; > 2 s absolute seek. While paused, never correct.
- Report every 5 s: `{offset_ms, rtt_ms, drift_ms, source:"mpv"|"simulate"}` with `activity_id:null`.
- stdin commands: `play`, `pause`, `seek <ms>`, `q`. Each becomes an `intent`.
- mpv control: spawn `mpv --idle=yes --no-terminal --input-ipc-server=<tmp>/wt-<pid>.sock`, speak JSON lines (`loadfile`, `set_property pause`, `seek absolute`, `set_property speed`, `get_property time-pos`). Poll `time-pos` at 1 Hz rather than relying on observe_property.
- Clean shutdown: quit mpv, close socket, remove socket file.

## Tests (must not need a real mpv)

1. Anchor math: `position_at` with rate/paused/anchors, including negative elapsed.
2. Simulated two-client convergence: start `wt_server` on port 0, connect two `--simulate` clients, `play`, assert both positions within 100 ms after 2 s and after a `seek 42000`.
3. Drift policy table: unit test the decision function (none / rate / seek thresholds) at boundaries 249/250/1999/2000 ms.
4. Token/create: `--create` path returns a joinable room (HTTP only, no mpv).

## Done means

`cargo test` green, `cargo clippy --all-targets -- -D warnings` clean, `cargo fmt --check` clean, and a `rust/README.md` section showing:

```bash
wt-play --create --file /tmp/test.mp4
wt-play --room <id> --token <token> --file /tmp/test.mp4
```

Plus a short report: files, tests, and the measured drift of two headless clients on one machine.
