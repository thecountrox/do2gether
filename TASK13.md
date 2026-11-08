# TASK: port the Opus v3 board to Flutter

Source of truth: `/home/ubuntu/.hermes/cache/scratch/opus-design-v3.html` (read it first — its CSS
variables and component specs are the design). Existing app: `app/` with theme.dart, home_screen.dart,
room_screen.dart and widgets/. Keep protocol/clock/room_client/player behaviour unchanged.

## Visual system

- Font family `MPlusRounded` (already bundled, weights 400/500/700/800/900). Remove Baloo/Nunito
  references from theme; keep the assets only if trivial.
- Adopt the board's CSS variables as Dart tokens: plum base, surface, candy gradient, cyan live,
  yellow accent, violet host, muted text, 2px borders, 20–28px radii.
- Update `WtBackground` to the board's plum + soft radial washes (no hard gradient edge).
- Buttons: one candy gradient per screen; ghost is 2px border; disabled is dashed 40%.
- Chips/pills: sticker style; key-cap code component `WtCode` becomes individual tiles with 8px gaps
  (the board's `K M R - 2 8 4` look), monospace-ish spacing.

## Home

Port phone 1 structure:
- wordmark + settings icon (settings opens the existing server sheet)
- invite field with Paste button, name chip
- when the pasted link parses: fetch `GET /rooms/{id}` (public) and show a live room card:
  host, members, playback item if any, and the primary `Join <host>'s room`; if the request fails,
  still allow join with the code.
- expired link: inline amber/red note (`That invite expired…`), join disabled
- secondary `Start my own room` card
- do NOT invent a "last time" history section — we have no persistence; leave it out.
- server URL stays behind the settings sheet; no raw URL on the main screen.

## Room ready

Port phone 2 as a `WtSheet` after `POST /rooms`:
- key-cap room code (from the 8-char room id, grouped e.g. `4F2K-9A`),
- invite link + Copy (Copied state 1.5s),
- optional file row: if a file was picked before creating, show name/size/hint; otherwise a
  `Choose your copy` ghost action that opens the file picker (the file is only needed to play,
  not to create),
- primary `Enter room`, ghost `Share`.
- Remove the room/token text fields from the old flow.

## Room

Port phone 3:
- 16:9 letterboxed video stage inside the phone/desktop area, black bars, rounded 24, 2px border.
  Empty state inside the 16:9: glowing `+`, `Open a file to watch together`, `Open file`.
- top: back, key-cap code chip (tap copies), sync pill (`In sync · N watching` / `Syncing` / `Off`),
  avatar stack.
- bottom dock: labelled controls `Back 10s`, gradient play/pause (72px), `Ahead 10s`, time current /
  remaining, thin progress bar with buffered hint and a drag handle (seek on release).
- narrow: people/queue in a sheet; wide (>=900): 320px right rail.
- disconnection banner; waiting-for-host-file state keeps the amber outline.

## Tests

Update widget tests for the new Home (expired link, valid link, paste parsing) and room-ready sheet
(code formatting). Keep all existing tests green; add a 360×800 and 1280×800 overflow pump for Home
and Room.

## Done

`flutter analyze` clean, `flutter test` green, Linux debug build with the documented env flags.
Report files, tests, and any place the board could not be ported 1:1.
