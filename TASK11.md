# TASK: UI/UX rebuild — "Noir Cinema"

Implement `docs/08-design.md` in `app/`. This is a visual and flow rebuild, not a behaviour change:
`protocol.dart`, `clock.dart`, `room_client.dart` and `player.dart` keep their logic. Only presentation
and navigation change.

## Files

```
lib/theme.dart            tokens + ThemeData (dark, Material 3)
lib/widgets/button.dart   WtButton (filled/ghost/danger, sizes, press scale .98)
lib/widgets/field.dart    WtField (56px, surface2, 16 radius, amber focus ring)
lib/widgets/identity.dart WtAvatar, WtAvatarStack (deterministic hue from user id)
lib/widgets/chrome.dart   WtChip, WtSyncDot, WtGlassBar, WtSheet, WtEmptyState, WtCode
lib/home_screen.dart      replaces join_screen.dart
lib/room_screen.dart      rebuilt layout
lib/main.dart             theme wiring
```

Delete `join_screen.dart` (or keep only a deprecated shim if tests import it — update tests instead).

## Home

- Centred column, max width 560; no AppBar.
- Wordmark `watch together` (display, -1.0 tracking) with a 6px amber dot after it; sub `One screen.
  Same moment.` in muted.
- Primary `WtField` labelled "Invite link" with a link icon; accepts:
  - `watchtogether://join?room=…&token=…`
  - `https://<host>/join/<token>` (decode the token payload to get room)
  - `roomId token` or `roomId:token` manual paste
  On valid input the field shows a small teal `● <roomId>` hint and the primary button enables.
- Primary button `Join a room` (amber, 56px, full width). Disabled at 40% until valid.
- Divider with `or`, then ghost button `Start a room`.
- Small footer: `Server <host> · Change` — tapping opens a WtSheet with the server URL field (default
  is the deployed host), saved in state only. No visible server form on the main screen.
- `Start a room`: POST via existing `_postRooms`; on success open `WtSheet` "Room ready":
  - `WtCode` big mono room code, caption `share this code`
  - the full invite link in a read-only field with `Copy link`
  - primary `Enter room`, ghost `Done`
  Name defaults to `Platform.localHostname` (use `You` when it returns `localhost`).
- Inline validation only; no snackbars for field errors. Network errors show a slim danger banner
  under the fields.

## Room

- No AppBar. `WtScaffold` fills the window.
- Top row overlay (12px inset): back chevron, `WtChip` room code (tap = copy, shows `copied` for 1.5s),
  spacer, `WtSyncDot` + `ms` chip (teal `in sync` < 80 ms, amber `syncing` < 400 ms, red `off`),
  `WtAvatarStack` of presence.
- Player fills the remaining space (max 16:9, centred, 24 radius, black). Empty state inside:
  film icon, `Open a file to watch together`, amber `Open file`. When waiting for a host file:
  amber-outlined state `Waiting for the host's file`.
- `WtGlassBar` floating 16px above the bottom: play/pause, −10, +10, current/total time (mono,
  muted), volume icon (mute toggle only), fullscreen icon (visual only, no-op with tooltip).
  Disabled at 40% until a file is open.
- Wide (>=900): 320px right rail — `In this room` (avatar, name, `you` tag) and `Queue` (item refs
  shortened, empty state `Nothing queued`).
- Narrow: people button opens `WtSheet` with the same two sections.
- Disconnected: slim banner `Reconnecting…` under the top row; controls disabled.

## Motion

- Page transitions: fade+slide 12px, 220 ms.
- Sheet: slide up 240 ms.
- Sync dot: pulse opacity 0.4–1.0, 2 s loop, only when connected.
- Buttons: scale .98 on press, 120 ms.

## Constraints

- No new dependencies. Material icons only. No network fonts.
- Keep every existing function: create room, join, presence, clock, intents, file open, drift,
  reports, waiting-for-file. Do not change protocol behaviour.
- Desktop hover states on all interactive elements.

## Tests

- Update existing widget tests for the new Home (invalid link disables the button, valid
  `watchtogether://` and `/join/<token>` links enable it and show the room id).
- Add pure tests for invite-link parsing (three formats + garbage) in `lib/links.dart`.
- `flutter analyze` clean, `flutter test` green.

## Done means

```
nix shell nixpkgs#flutter -c bash -c 'cd app && flutter analyze && flutter test'
```

green, plus a build: `flutter build linux --debug` on this host using the documented env
(`CC=/usr/bin/clang CXX=/usr/bin/clang++ LDFLAGS="-L/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib -Wl,-rpath,/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib"`).
Report files, tests, and any place where the design doc was ambiguous.
