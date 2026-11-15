# TASK: player UX pass (Room screen)

The room works; the player around it is thin. This is a UX pass on the Room screen only: the stage, the
transport dock, the seek bar, tracks, and the states around playback. Keep the candy style and the
existing widgets; keep the sync engine, protocol, clock and intents untouched.

Current: 127 Flutter tests green, `flutter analyze` clean except two pre-existing infos, goldens in
`app/test/golden/` (`room_1440.png`, `room_856.png`). The design authority is you — but a reviewer
listed these, ranked by impact, and most of them are fair. Fix what is real, note what you reject.

## 1. The stage lies by being silent (highest impact)

The stage is a black rectangle whether it is playing, buffering, waiting for the host, failed, or
ended. Give it real states, each visually distinct and none of them a bare black box:

- **Opening / buffering**: a spinner plus "Opening your copy…" or "Buffering…", with the file name.
- **Waiting for someone**: "Waiting for Mika to press play" (name the person when the anchor names
  them), so a paused room never looks broken.
- **Error**: a card with the reason (missing file, HTTP 404, unsupported codec) and a `Try again` plus
  `Choose another file` action.
- **Ended**: "Finished" with `Replay` and, when the queue has a next item, `Play next` + the title.
- **Mismatch** (file open, not the room's file): keep it but make the message actionable — say which
  file the room is playing and offer `Open that file…`.

## 2. Transport dock

- Play/pause: stateful icon, and it should read as the primary control (it does not today).
- `-10s` / `+10s`: labelled, not just icons. Disabled (with a reason) when you have no file.
- Volume: a slider that expands from the icon on hover/focus, plus a clear muted state; remember the
  level across the session.
- Fullscreen: keep the icon, add a visible exit affordance in fullscreen and hide the chrome after
  2.5 s of no pointer movement (cursor hidden too).
- Speed: 0.5× / 0.75× / 1× / 1.25× / 1.5×, shown when not 1×. Rate nudges from the drift engine must
  not be presented as user speed — show the user's choice only.
- A small `?` that opens the shortcut sheet (see 5).

## 3. Seek bar

- Buffered range drawn behind the played range.
- Hover: a time tooltip and a subtle fill preview; drag to scrub, committing one `seek` intent on
  release (not a burst while dragging).
- Click anywhere on the bar seeks; keyboard focus with arrows ±5 s.
- Show remaining time on the right when the pointer is over the bar, `-12:04` style.

## 4. Tracks and source

- An audio/subtitle popover listing the tracks media_kit reports (audio tracks, subtitle tracks, and
  `Off` for subtitles). Nothing fancy: a list with the active one marked. If the platform reports no
  tracks, the button is hidden rather than broken.
- Now-playing row must say where the media came from: `Jellyfin` chip for `jellyfin:` refs, `Local
  file` otherwise — and for Jellyfin use the name the picker supplied, never "Host's file".
- Sync state next to the time: `In sync`, or `Adjusting` while a correction is in flight (the
  `SyncPlayer` already knows: `Correction` and `driftMs`). This is the one number people actually want.

## 5. Shortcuts

`Space` play/pause, `←/→` 5 s, `Shift+←/→` 30 s, `F` fullscreen, `M` mute, `Esc` leave fullscreen,
`?` open the shortcut sheet. Show them in a small overlay, and put a "Shortcuts" line where keycaps are
shown today. **The room code currently renders as keycap chips (K 3 F 9 X 2 Q A) and reads like
keyboard shortcuts** — separate those two ideas visually.

## 6. Ready pill

`2 of 4 ready` is unexplained. Give it a tooltip or popover listing who is not ready and why (No file,
Buffering), and make the people rows carry that reason.

## Constraints

- No protocol, clock, drift-policy, intent or server changes. `SyncPlayer` internals stay as they are
  except for read-only exposure you need (user rate vs nudge rate, current correction).
- Keep the candy palette, M PLUS Rounded, the existing widget vocabulary (`WtButton`, `WtIconButton`,
  `WtDashed`, …). New surfaces reuse them; no new fonts, no new packs.
- Fullscreen auto-hide must not fight the golden tests: tests pump with no pointer and expect chrome.
- Widget tests for each new state (loading, waiting, error, ended) and for the seek bar's scrub
  commit and the shortcut sheet. Update the goldens, add a player-state golden if it helps.
- `flutter test` green, `flutter analyze` no new issues, `flutter build linux --debug` passes.

Report: what changed per section, what you rejected and why, test count, and the golden paths.
