# TASK: make fullscreen actually immersive

Fullscreen today: the stage fills the window, the dock is a solid full-width bar pinned to the bottom,
an `Exit fullscreen` button sits top-right, and chrome fades after idle. It still reads like the normal
room with the borders filed off. Make it a viewing mode.

## What "immersive" means here

1. **The picture is the interface.** Video letterboxes to the biggest 16:9 (or 2.39:1) rectangle that
   fits, centred, on pure black — never stretched, never padded by window margins, never pushed off
   centre by the dock.
2. **Chrome is a guest.** No solid bars. The transport is a floating pill over a soft scrim so it stays
   readable on a bright frame; the top strip (room title, people count, exit) is a small translucent
   cluster, not a 64px bar with a border.
3. **Everything gets out of the way.** After 2.5 s without pointer movement *or* a key, chrome fades to
   zero and **the cursor hides for real** (`MouseRegion(cursor: SystemMouseCursors.none)`), not just an
   opacity change. Any pointer move, click, or key brings it back. It must hide whether playing or
   paused — a paused frame with a dock stuck on it is not immersive.
4. **The stage is clickable.** Click the picture: play/pause. Double-click: toggle fullscreen. Do not
   swallow clicks meant for the dock.
5. **One way out, three ways to find it.** `Esc` exits, `F` toggles, and the exit control is visible
   whenever the chrome is up. On entering fullscreen, a one-off hint ("Esc to exit · F toggles") fades
   after ~2 s and never blocks a click.

   **Owner requirement (2026-11-15): do not make anyone wait for chrome to fade in.** A persistent,
   always-visible control sits in the corner for the whole fullscreen session — a small
   `Exit fullscreen` pill (plus a `Show controls` toggle is welcome) that never auto-hides, with reduced
   contrast so it does not fight the picture. Chrome fading in on pointer move stays as a bonus, never
   as the only route to the controls.
6. **No surprises on return.** Leaving fullscreen restores exactly the normal layout, dock state and
   pointer behaviour.

## Keep

- The existing dock content in fullscreen: `-10s` / play / `+10s`, timecode, sync tag, speed, scrubber
  with buffer and hover tooltip, track menu, volume, `?`.
- The auto-hide test seam: tests pump without pointing, so `_pointerSeen` being false must keep chrome
  visible (see `chromeHideAfter` and the existing fullscreen tests in `room_view_test.dart`). Add a way
  to drive idle in tests rather than sleeping.

## Constraints

- Room screen only. No protocol, clock, drift, or intent changes.
- Reuse the candy palette and existing widgets; no new fonts or packages.
- Widget tests: chrome hides after the idle window (fake the clock, do not sleep), any pointer move
  restores it, stage click toggles play/pause, double-click toggles fullscreen, Esc exits.
- Add a golden of the fullscreen state at 1440×900 — both chrome visible and chrome hidden.
- `flutter test` green, `flutter analyze` no new issues, `flutter build linux --debug` passes.

Report: what changed, how the idle timer is driven in tests, test count, golden paths, and anything you
rejected.
