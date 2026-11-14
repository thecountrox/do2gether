# TASK: port the hybrid board (v3 flow + v2 skin)

Reference: `/home/ubuntu/.hermes/cache/scratch/opus-hybrid.html` — it is the v3 board with a v2 skin
override appended in a `<style>` block at the end of `head`. Read that file; the override block is the
authoritative palette/glow.

The app currently renders the Candy Stage baseline (committed). Keep its playful character; port the
hybrid's structure and its richer v2 palette. Do not use v3's muted palette.

## Tokens (from the override)

```
board    #0C0613
plum     #1A0E27
s1       #2B1945
s2       #362056
line     rgba(255,232,248,.20)
text     #FFF4FB
tx2      #EBDDF2
tx3      #D4C0E2
grad     linear-gradient(135deg,#D93583 0%,#A63AC6 52%,#6A45F2 100%)
cyan     #62EAF4
yellow   #FFD45E
```

Button glow: `0 12px 30px -10px rgba(226,58,150,.75), 0 4px 18px -8px rgba(110,70,240,.6), inset 0 1.5px 0 rgba(255,255,255,.55)`.
Font stays `MPlusRounded`.

## Home (v3 structure, v2 skin)

- Header: small eyebrow (`FRIDAY NIGHT`-style is sample copy; use `WATCH TOGETHER`), wordmark, settings.
- Invite field with Paste + name chip.
- On a valid link: decode the token, call `GET /rooms/{id}` (verify it exists in the server; it does)
  and show a **room-found card** above the join CTA:
  - check + `Room found`, key-cap code tiles, live pill if playback/members present,
  - host name, member count, item title if any (`item_ref` shortened when no title),
  - primary `Join <host>'s room`, disabled until lookup resolves or fails-open.
- Expired link: dashed warning card, code + expiry, CTA `Ask for a fresh link`, join disabled.
- Secondary `Start my own room`.
- No server URL on screen; settings sheet only.

## Room ready (sheet)

- Key-cap code tiles, invite link + Copy (Copied 1.5s), optional file row (`Choose your copy` if none),
  primary `Enter room`, ghost `Share`.
- Keep the returned `host_id` for identity, as the baseline already does.

## Room

- 16:9 letterboxed stage inside the rounded frame; black bars; empty state centered.
- Top: back, key-cap code chip (copy), sync pill (`In sync · N watching`), avatar stack.
- Bottom dock: labelled `Back 10s` / gradient play-pause / `Ahead 10s`, time current / remaining,
  progress bar with drag-to-seek on release.
- Event toast above the dock, auto-hides after 4s, never covers video for long (show on remote seek
  or pause when the state change did not originate locally).
- Wide >=900: right rail (people + queue); narrow: sheet.
- Disconnected banner; waiting-for-host-file state.

## Tests

Update widget tests for: link parse (expired / valid / garbage), room-found card rendering with a
stubbed HTTP client, key-cap formatting, Home overflow at 360×800 and 1280×800. Keep all other tests.

## Done

`flutter analyze` clean, `flutter test` green, Linux debug build with documented CC/CXX/LDFLAGS.
Report files, tests, and any 1:1 gaps.
