# Roadmap

Status 2026-11-08: v0/v1 shipped — Rust room server (SQLite, permissions, bot API, metrics) deployed,
`wt-play` mpv client, Flutter desktop client, Android release APK, Discord bot live in Mikunomics.

Ordered by leverage, not novelty.

## 1. Join link + identity-bound tokens (~1 evening)

**Problem.** The bot DMs a raw room id and token; the app takes both by paste. `hello` claims its
own `user_id`, so a token is room-bound but not user-bound.

**Work.**
- `GET /join/<token>` on the room server: decode the token, show room id, "Open the app" button
  (`watchtogether://join?room=…&token=…`), and a copyable manual fallback.
- Flutter: register the `watchtogether` URL scheme; parse the deep link and prefill the join form.
- Tokens gain an optional `sub` claim; when present, `hello` must match it. Bot tokens carry it;
  `POST /rooms` mints the host's.
- Bot invite DM becomes the link.

**Done when.** A new user clicks a link on their phone, the app opens prefilled, and they're in the
room without typing anything.

## 2. Music mode: Navidrome host-stream (2–3 evenings)

**Problem.** "Listen" is designed but unimplemented.

**Work.**
- Subsonic/Navidrome adapter: browse, stream with range requests, `subsonic:<server>/<track>` refs.
- Host-stream sync: `play_at = server_now + 2–3 s`, clients buffer and start on the beat; late joiners
  tune in. Drift is a buffer problem, not a clock problem.
- CLI and Flutter playback paths; no tempo bending, corrections only at phrase boundaries.
- Queue UI in Flutter (DJ mode is the wedge).

**Done when.** Two clients play the same track within ~150 ms and survive a 5 s network drop.

## 3. Voice-gate live test (30 min, needs a human in a call)

Unit-tested only. Run `/room create` and `/room invite` against real voice states, confirm a user
outside the call is refused and one inside gets a token.

## 4. Bot hardening (1 evening)

- Persist room↔channel bindings (bot restart forgets them today).
- Card refresh loop with idle timeout; edit in place, respect rate limits.
- Queue buttons; "who's diverged" from `/stats`.
- Per-viewer Close is impossible on a shared card today — keep it ephemeral, or move controls to a
  mod-only channel.

## 5. YouTube extension, then YTM spike (3–5 evenings)

- TS extension speaking the room protocol; YouTube via the official IFrame API.
- YTM only as a gated spike: read title/position from the page, detect ads, show a per-user
  "diverged" chip, never pause the room for one person's ad.
- Do not build this before 1 and 2; it is the highest-maintenance surface in the product.

## 6. Flutter polish / Android runtime (ongoing)

- Actual install and watch on a phone — the APK has never run on a device.
- Queue UI, subtitle controls, fullscreen, audio-device picker.
- Replace the desktop debug-signing path with a real release key when distributing beyond friends.

## Known gaps (accepted)

- Release APK is debug-signed; Android release AOT needs the x86_64 build host (gigapc).
- Rooms expire after 24 h idle; no archival.
- `/metrics` and `/stats` are public, no auth (no secrets in them).
- Process counters reset on restart; drift percentiles are in-memory.
- No horizontal scaling; one process, one SQLite file, by design at this scale.

## Open decisions

- Join link target: web page first, or app deep link first? (Blocks item 1.)
- Bot as a separate application (current) vs a namespaced Clawn plugin.
- Whether to expose a web client for YouTube rooms (zero install) before the extension ships.
