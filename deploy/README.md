# Deploy (this VPS)

Live at **https://watch.141.253.97.15.sslip.io** — Caddy terminates TLS and proxies the WebSocket to a loopback-bound binary.

## Pieces

| Thing | Where |
|---|---|
| Binary | `rust/target/release/wt-server` (2.6 MB) |
| Service | `/etc/systemd/system/wt-server.service` (`wt-server`) |
| Env | `deploy/wt-server.env` — `WT_SECRET`, `BIND=127.0.0.1`, `PORT=8787` (gitignored) |
| Caddy block | `deploy/Caddyfile.watch`, appended to `~/.local/etc/caddy/Caddyfile` |
| Caddy service | `pull-picker-proxy.service` (admin off, so restart it to apply) |

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
