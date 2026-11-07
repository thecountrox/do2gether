# TASK: TLS for wt-play (join the deployed server)

`wt-play` is HTTP-only right now (`net.rs` rejects `https://`). The server is deployed behind Caddy at `https://watch.141.253.97.15.sslip.io`, so the client must speak `wss://` and `https://`.

## Scope

1. **WebSocket over TLS.** Enable rustls in `tokio-tungstenite` (`rustls-tls-native-roots`) and connect with the `wss://` URL when the server URL is `https://`. Native roots, not webpki-roots, so the box's trust store applies.
2. **`POST /rooms` over TLS.** Either a small `tokio-rustls` HTTP/1.1 client or `ureq` with rustls in `spawn_blocking`. Keep the dependency addition proportionate; do not pull in reqwest for one request.
3. **URL parsing.** `ServerUrl` keeps `scheme`; `ws_url()` returns `ws://` or `wss://` accordingly; default port 443 for https, 80 for http. Existing http tests must keep passing.
4. **No insecure mode by default.** Do not add a "skip certificate verification" flag.

## Tests

- Unit: URL parsing for `https://host`, `https://host/path`, `https://host:8443`, and `http://host:8787`; `ws_url` scheme and port.
- Integration (ignored by default with `#[ignore]`, run manually): create a room over `https://watch.141.253.97.15.sslip.io`, join with `--simulate`, receive `welcome`, send `play`, exit 0. Name it `live_tls_roundtrip`.
- All existing tests stay green.

## Done means

`cargo test` green, `cargo clippy --all-targets -- -D warnings` clean, `cargo fmt --check` clean, and this command works from this VPS:

```bash
./target/debug/wt-play --server https://watch.141.253.97.15.sslip.io --create --simulate --name tls-test
```

Report the command output and the rustls dependency count delta.
