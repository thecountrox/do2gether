# do2gether

Watch, listen and do things together. One room, everyone's own player, in sync. Discord is the
lobby; the app is the screen.

**Shipped (v1):** Linux + Windows desktop client, Rust room server, Discord bot.

| Thing | Where |
|---|---|
| Room server | https://watch.141.253.97.15.sslip.io (`/health`, `/metrics`, `/stats`) |
| Discord bot | `watch-together#6690`, `/room create`, in the Mikunomics guild |
| Linux build | https://files.141.253.97.15.sslip.io/user_uploads/watch-together/do2gether-linux-x64.tar.gz (19 MB) |
| Windows build | https://files.141.253.97.15.sslip.io/user_uploads/watch-together/do2gether-windows-x64.zip (40 MB) |
| Source | private `thecountrox/do2gether` |

## Install and run

**Linux:** extract the tarball and run `bundle/watch_together`. No installer needed — on first run the
app registers `do2gether://` with your desktop, so invite links open it directly.

**Windows:** unzip and run `watch_together.exe`. The first run writes `HKCU\Software\Classes\do2gether`
so invite links work without an installer or elevation.

**Invites:** `/room create` in Discord DMs you a join link → the join page's button is
`do2gether://join?room=…&token=…` → clicking it opens the app with the room already filled in.

## What works today

- Rooms with HMAC join tokens (10 min TTL, user-bound), embeddings of `host`/`all` control modes,
  lock/kick, 24 h idle TTL, SQLite persistence across restarts.
- Four-timestamp clock exchange, server-authoritative anchor, drift policy: ignore <250 ms, rate nudge
  250 ms–2 s, hard seek >2 s.
- Flutter desktop client: Home launcher, Room ready dialog, player + member rail + dock, candy palette,
  responsive down to a tiled 856 px window.
- Invite deep links on both desktop platforms; the app self-registers the URL scheme, and a second
  launch hands its invite to the window that is already open instead of opening another.
- `wt-play` CLI (mpv over JSON IPC) for headless sync, plus `scripts/drift-check.py`.

**Measured:** two clients, deployed server, `p95 0 ms / max 1 ms` (simulated players on one host, so it
proves the anchor math, not WAN jitter). Earlier real-mpv run over the public endpoint: p95 119 ms.

**Tests:** Rust 63 + 3 CLI integration, Flutter 105, bot 8 — green. `cargo clippy -D warnings` and
`flutter analyze` clean (two pre-existing info lints).

## Layout

```
app/         Flutter desktop client
rust/        wt-protocol, wt-server, wt-cli (wt-play)
bot/         Discord bot (discord.js)
server/      TypeScript reference implementation (delete after the Rust one proves itself)
protocol/    room.schema.json — canonical wire format
docs/        spec, protocol, decisions, stack, roadmap, design
deploy/      systemd units, Caddy block, ops notes
scripts/     desktop-shot.sh, deploy-linux.sh, launch-and-shot.sh, drift-check.py, demo-local.sh
```

## Quick start (local)

```bash
cd rust
cargo build --release -p wt-server -p wt-cli
WT_SECRET=dev ./target/release/wt-server          # terminal 1

./target/release/wt-play --server http://127.0.0.1:8787 --create --file /tmp/movie.mp4
./target/release/wt-play --server http://127.0.0.1:8787 --room <id> --token <token> --file /tmp/movie.mp4
```

`wt-play` stdin: `play`, `pause`, `seek <ms>`, `q`.

Two-client drift against the deployed server:

```bash
python3 scripts/drift-check.py     # host creates; guest token minted through the bot API
```

## Known gaps

- Guests must have their own copy of the file (or a URL ref); no Jellyfin adapter yet.
- A forwarded invite updates the open window but does not raise it to the front (no platform
  window-raise yet).
- Drift settles 100–180 ms after a seek: fine for video, not for music (needs the host-stream model).
- Windows build is CI-produced and unsigned; SmartScreen will warn.
- Music (Navidrome/Jellyfin) and YouTube sources are designed, not built.

## Next

1. Jellyfin direct-play adapter (`jellyfin:<server>/<item>`), no server egress.
2. Single-instance deep links (focus the running window and hand it the invite).
3. Rename pass to `do2gether` for ids/binary/service names.
4. Phone companion remote: join, now-playing, transport — no decoding.
