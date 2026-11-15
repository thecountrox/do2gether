# TASK: Jellyfin as a media source (v1.1)

Local files work. Add Jellyfin direct-play so a room can watch something nobody has on disk: the room
carries only a reference, each client pulls its own stream from *its* Jellyfin. The room server never
carries media bytes.

A live Jellyfin is already running and publicly reachable — use it for real verification:

```
server   https://jelly.141.253.97.15.sslip.io
user     root
password (empty)
item     8b2ab2fa2506721d49db38751b5142c9   ("sample-room", 1280x720 h264+aac, 20 s)
token    read from /tmp/jf_item.txt line 2 on this host (also: scripts/jellyfin-setup.py)
stream   {server}/Videos/{itemId}/stream?static=true&api_key={token}   -> verified 200 video/mp4
```

## Item ref (already in the protocol — do not change it)

```
jellyfin:<host>[:<port>]/<32 lowercase hex itemId>
```

`item_ref.rs`, `protocol/room.schema.json` and `app/lib/protocol.dart` already accept it, with tests.
`host` is the host every client can reach (`jelly.141.253.97.15.sslip.io`, LAN ip, whatever) — the
ref must be byte-identical for everyone in the room, which is why it is in the ref and not in settings.

## What to build in `app/`

1. **`lib/jellyfin.dart`**
   - `({String host, String itemId})? parseJellyfinRef(String ref)`.
   - `String streamUrl({required String server, required String token, required String itemId})` →
     `{server}/Videos/{itemId}/stream?static=true&api_key={token}`.
   - `Future<JellyfinSession> signIn({required Uri server, required String user, required String pass})`.
     `POST {server}/Users/AuthenticateByName` body `{"Username","Pw"}` with the header
     `Authorization: MediaBrowser Client="do2gether", Device="desktop", DeviceId=<stable>, Version="0.1.0"`.
     **This build returns 401 for `X-Emby-Token` and for `?api_key=` on `/Items`; the `Authorization`
     header with `Token="<tok>"` appended is the one that works.** Keep that in mind for anything that
     lists items.
   - `Future<List<JellyfinItem>> movies()` → `GET {server}/Items?Recursive=true&IncludeItemTypes=Movie&Limit=100&SortBy=SortName`
     with the Authorization+Token header; map `Id`, `Name`, `RunTimeTicks` (ticks/10^7 = seconds).
   - Config: `~/.config/do2gether/jellyfin.json` (`%APPDATA%\do2gether\jellyfin.json` on Windows)
     holding `{"server":…, "token":…, "user":…}`. Load at startup; save after a successful sign-in.

2. **`lib/local_copy.dart`** — a copy can now be remote. Keep `itemRef`; add an optional `isRemote`
   (or a `LocalCopy.remote(...)` constructor) so the join card can show `Jellyfin · 0:20` instead of a
   byte size, and so nothing tries to hash a URL.

3. **`lib/player.dart`** — `SyncPlayer.open` hashes the path; remote refs must skip that. Add
   `openSource({required String uri, required String itemRef})` and route room playback through it
   when the copy is remote. media_kit plays the https URL as-is.

4. **`lib/home_screen.dart`** — next to "Choose file" add a `Jellyfin` action:
   - dialog with server / user / password (server pre-filled from saved config),
   - `Connect` → sign in, save config, then a picker listing movies (name + runtime),
   - picking one sets the room copy to `jellyfin:<host from the server URL>/<itemId>` with the movie
     name as its display name and enables Join.
   - If nobody is signed in yet, the action just opens the dialog. Failures show the server's message,
     not a generic error.
   Reuse the existing candy widgets/typography — this is new UI, so it must look like the rest.

## Verification (must actually run)

- Unit tests: ref parsing (good/bad), `streamUrl`, config round-trip in a temp dir, tick→duration.
- Widget test: the Jellyfin dialog with an injected fake session (no network) reaching the movie list
  and selecting one.
- `flutter test` green (currently 108 + 1 skipped), `flutter analyze` no new issues.
- Headless proof the URL is real: `curl -o /dev/null -w '%{http_code} %{content_type}'` against the
  stream URL you build, printed in your report.
- `flutter build linux --debug` with the documented nix env.

## Do not

- Do not change the room protocol, the clock, drift policy or token handling.
- Do not put credentials in the repo, logs or tests; the config file is user-local and gitignored.
- Do not restyle existing screens.

Report: files changed, test counts, the curl line, and anything in the Jellyfin API that fought you.
