# Deploy (this VPS)

Live at **https://watch.141.253.97.15.sslip.io** — Caddy terminates TLS and proxies the WebSocket to a loopback-bound binary.

## Pieces

| Thing | Where |
|---|---|
| Binary | `rust/target/release/wt-server` (2.6 MB) |
| Service | `/etc/systemd/system/wt-server.service` (`wt-server`) |
| Env | `deploy/wt-server.env` — `WT_SECRET`, `WT_BOT_TOKEN`, `WT_DB`, `BIND=127.0.0.1`, `PORT=8787` (gitignored) |
| Caddy block | `deploy/Caddyfile.watch`, appended to `~/.local/etc/caddy/Caddyfile` |
| Caddy service | `pull-picker-proxy.service` (admin off, so restart it to apply) |
| Database | `/home/ubuntu/watch-together/data/wt.db` (SQLite, WAL) |

## Endpoints

```
POST   /rooms                  create (optional {host_id, host_name, guild_id, voice_channel_id})
GET    /rooms/{id}             public snapshot (no tokens)
POST   /rooms/{id}/tokens      bot auth; mint a join token for {user_id, user_name}
PATCH  /rooms/{id}             bot auth; {locked?, controls?}
DELETE /rooms/{id}             bot auth; close and delete
GET    /metrics                Prometheus text
GET    /stats                  JSON per-room drift and counters
GET    /health
WS     /ws?room=&token=
```

Bot endpoints require `Authorization: Bearer $WT_BOT_TOKEN`; they 404 when the env var is unset.

## Restarts

Rooms are written through to SQLite inside the room lock, so a service restart no longer drops
them: rooms, playback anchors and queues reload from `wt.db`, members rebuild from new connections.
`WT_SECRET` must stay stable or every outstanding join token dies with it.


## Rebuild and restart

```bash
cd rust && CARGO_BUILD_JOBS=2 cargo build --release -p wt-server
sudo systemctl restart wt-server
curl -s https://watch.141.253.97.15.sslip.io/health
```

## Logs

```bash
journalctl -u wt-server -f
tail -f ~/.local/share/caddy/watch-access.log
```

## Notes

- `BIND=127.0.0.1` is deliberate: Caddy is the only public door.
- `WT_SECRET` is generated with `openssl rand -hex 32`; rotating it invalidates every outstanding join token (10-minute TTL), which is the intended kill switch.
- Rooms live in memory. Restarting the service drops all rooms; clients get 4004 on reconnect and must create a new room.
