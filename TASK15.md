# TASK: implement the approved desktop UI in Flutter

Design source of truth: `docs/design/home.html`, `docs/design/room.html`,
`docs/design/room-ready.html` and their `.png` renders. Owner approved the direction; implement it in
`app/` without inventing a new visual language.

Desktop-first: Windows + Linux, default 1440x900, minimum 1100x720. Phone layouts are out of scope for
this pass (leave the Android runner building, but do not optimise for phones).

Keep behaviour: `protocol.dart`, `clock.dart`, `room_client.dart`, `player.dart` logic is unchanged.
`links.dart` parsing stays. Only presentation, layout, widgets and local UI state change.

## Tokens (from the boards)

```
board #0C0613 · plum #1A0E27 · s1 #2B1945 · s2 #362056
line rgba(255,232,248,.20) · text #FFF4FB · tx2 #EBDDF2 · tx3 #D4C0E2
grad linear-gradient(135deg,#D93583 0%,#A63AC6 52%,#6A45F2 100%)
cyan #62EAF4 (live/sync only) · yellow #FFD45E (tiny accents) · danger #FF6B6B
font MPlusRounded (already bundled, weights 400/500/700/800/900)
radius 10 (chips), 16 (controls/rows), 24 (surfaces), 999 (pills)
spacing 4/8/12/16/24; window padding 24; rail padding 16
```

Update `theme.dart` to these exact values; remove Baloo/Nunito references from the theme (assets may
stay). Buttons: gradient with `inset 0 1.5px 0 rgba(255,255,255,.55)` highlight and the pink/violet
glow; ghost = 2px border; pressed scale .96 with 120ms; focus ring cyan 2px offset 3.

## Home — split launcher

- 12-col grid; brand column 300-340; action card 480-520; both optically centred.
- Brand column: wordmark + sparkle, `One screen. Same moment.`, three steps with states (paste invite ·
  open your copy · press play), bottom status row `Connected to <host> · <rtt> ms · Change server`.
  No dead vertical space: distribute with spaceBetween, cap the column height.
- Action card: `Join a room`, invite field with Paste icon button, name chip (`as <name>`), room-found
  card when the link parses (key-cap code, host + avatars, item line, live pill), primary gradient
  `Join <host>'s room` disabled with a reason when no local file is open yet (`Open your copy to
  join`), compact secondary `+ Start a room` with hint.
- Inline invite errors under the field, calm not red: expired-but-room-alive (with `Ask for a new
  link`), room ended, malformed link.
- Fetch `GET /rooms/{id}` after parsing a link; fail open (show code, allow join) if lookup fails.

## Room ready — dialog

- Centered 520px dialog over a dimmed Home (55% black scrim).
- Key-cap code as hero; caption `read it out — no 0/O or 1/I`; invite link + Copy (Copied 1.5s).
- Readiness list: avatar, name, state chip (`Ready / Invited / No file yet`), nudge action on the last.
- Your copy row: file glyph, name, size · duration, `Choose your copy` / `Change`.
- Footer: gradient `Enter room`, ghost `Share`, quiet line `Code expires in <mm:ss> · anyone in the room
  can invite`. Fix the board's contradictions: do not show "Nothing is uploaded" next to a file; use
  `Plays from your disk`.

## Room — desktop player

- Top bar 64: back, app wordmark + room name + key-cap code (copy), yellow `N of M ready` pill that
  becomes cyan `All M in sync`; no duplicate avatar stack (rail owns presence); settings.
- Stage: size to media aspect inside the available area, 16:9 and 2.39:1 both correct, picture radius
  10, board-coloured letterbox, no border around bars. Empty state: glow +, `Open a file to watch
  together`, gradient `Open file`. Waiting: amber outline, `Waiting for the host's file`.
- Right rail 320: `In this room` with per-person state (`Synced / Buffering / Drifting ±2s / No file /
  Reconnecting`), host tag; `Queue` with pinned `Now playing` row and `Up next` file glyphs; empty
  `Nothing queued`.
- Dock 88: labelled `Back 10s`, gradient play/pause, `Ahead 10s`, now-playing filename, current/total,
  thick scrubber (8px track, 14px handle) with buffered hint, volume + fullscreen. Disabled at 40%
  until a file is open.
- Toast docked 12px above the dock, centered on play, 160ms enter; action `Resume`; after it hides,
  keep a persistent `Paused by Sam · 12:04` badge on the stage.
- Focus/keyboard: `Space` play/pause, `←/→` ±10s, `F` fullscreen, `M` mute, visible focus rings,
  slider with semantics and ARIA-equivalent.
- Reconnect banner `Reconnecting…`, controls disabled; room stays visible.

## Tests

- Keep all existing tests green; update widget tests for the new Home and Room.
- Add pump tests at 1440x900 and 1100x720 for Home and Room with no overflow.
- Add a test for the ready pill text (`N of M ready` → `All M in sync`).

## Build

`nix shell nixpkgs#flutter -c bash -c 'cd app && flutter analyze && flutter test'` clean, then
`flutter build linux --debug` with `CC=/usr/bin/clang CXX=/usr/bin/clang++` and
`LDFLAGS="-L/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib -Wl,-rpath,/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib"`.

Report files, tests, build path, and any board detail that could not be ported 1:1.
