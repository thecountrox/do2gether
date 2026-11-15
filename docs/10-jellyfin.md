# Jellyfin as a media source

The room carries a reference, never bytes. Each client resolves that reference against its own
Jellyfin and pulls its own stream, so the room server stays a control plane.

## Ref format

```
jellyfin:<host>[:<port>]/<32 lowercase hex itemId>
```

Example: `jellyfin:jelly.141.253.97.15.sslip.io/8b2ab2fa2506721d49db38751b5142c9`

The host is in the ref on purpose: everyone in the room must produce a byte-identical `item_ref` for
the sync check to match, and two people may be pointed at different Jellyfin installs. Credentials are
never in the ref — each client signs in locally and keeps its own token.

## Client resolution

```
GET {server}/Videos/{itemId}/stream?static=true&api_key={token}
```

`static=true` means direct play: Jellyfin hands back the original file (verified `200 video/mp4`). No
transcoding, no server egress through us, and seeking works because it is a plain range request.

## API quirks this build has (12.4.0)

- The startup wizard auto-creates a user named `root` with an **empty password**; `POST /Startup/User`
  then 404s. Sign in as `root` / `""` to bootstrap.
- `GET /Items` returns **401** with `X-Emby-Token` or `?api_key=`. It needs the full
  `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="<token>"`
  header.
- `/Videos/{id}/stream` accepts `?api_key=` fine, which is what the client uses — a plain URL is all
  `media_kit` needs.
- `POST /Users/New` returned 401 even with a valid admin token; bootstrapping through `root` avoids it.

## Bringing one up (what is running on this VPS)

```bash
mkdir -p ~/jellyfin/{config,cache,media}
docker run -d --name jellyfin --restart unless-stopped \
  -p 127.0.0.1:8096:8096 \
  -v ~/jellyfin/config:/config -v ~/jellyfin/cache:/cache -v ~/jellyfin/media:/media \
  jellyfin/jellyfin:latest
python3 scripts/jellyfin-setup.py         # wizard, library, scan, prints the first item + token
```

Public TLS: `jelly.141.253.97.15.sslip.io` → `127.0.0.1:8096` in the Caddyfile, so clients on other
machines can reach it. Bound to loopback, never 0.0.0.0 — Caddy is the only front door.

`scripts/jellyfin-setup.py` is idempotent: it reuses an existing library and prints the current first
item.

## Hosting a Jellyfin item without clicking through the app

```bash
python3 scripts/host-anchor.py \
  --ref jellyfin:jelly.141.253.97.15.sslip.io/8b2ab2fa2506721d49db38751b5142c9
```

It creates a room over HTTP, opens the websocket as the host, sends a `play` intent with that ref, and
prints `{room, token, ws}`. Useful for testing a guest client against a live anchor.

## Not done yet

- No library browsing UI beyond the picker in the join card.
- No transcoding policy: if a client cannot direct-play a codec, playback fails rather than asking
  Jellyfin for a transcode.
- No per-user token refresh; an expired token means signing in again.
