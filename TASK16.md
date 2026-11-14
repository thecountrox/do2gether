# TASK: fix what the real renders exposed

The Flutter desktop UI is implemented and green (73 tests). Renders at 1440x900 are in
`app/test/golden/home_1440.png` and `room_1440.png` (regenerate with
`flutter test test/golden/desktop_golden_test.dart --update-goldens`). Fix these, in this order.

## 1. Ready pill is wrong for default members (bug, high)

In the room render the pill says `0 of 4 ready` while Mika and Sam are shown as `Synced`. A
`RoomPerson` with no explicit state must count as synced/ready; only `noFile`, `buffering`,
`reconnecting` and `drifting`(beyond tolerance) are not ready. Fix the default and the counting so a
freshly joined room reads `All N in sync`.

Add a test: four people with default state → `All 4 in sync`; flip one to `noFile` → `3 of 4 ready`.

## 2. Stage aspect (bug, medium)

The video stage renders ~1.63:1 instead of 16:9. It must be exactly 16:9 (and 2.39:1 when the file
says so) regardless of the placeholder child, centred in the space left of the rail, never stretched.
Add a test asserting the stage's aspect ratio is 16/9 ± 0.01 at both desktop sizes.

## 3. Sub-1100 width (bug, medium)

Hyprland tiles the window to 856×1038 on a 1920 screen and ignores GTK min-size hints, so the Home
split clipped its right card. Below ~1024 width:
- Home: stack the brand column above the join card (single column, scrollable), hide the 3-step
  explainer behind a `How it works` disclosure, keep the join card full width.
- Room: collapse the 320px rail into an overlay sheet behind a people button; stage keeps 16:9.
Add pump tests at 856×1038 for both screens with no overflow.

## 4. Small polish (low, only if cheap)

- `NEXT` badge in step 1 is cramped against the word "invite" — give it 8px leading space.
- `Ctrl V to paste` hint sits too close to the field edge — 12px inset.
- Make `Change server` look like a control (ghost chip), not pink plain text.
- Align the checkbox with the first line of its label.

## Constraints

- Do not change protocol/clock/room_client/player behaviour.
- Keep the candy palette and M PLUS Rounded.
- `flutter analyze` clean (no new infos), `flutter test` green, then
  `flutter build linux --debug` with the documented nix env.
- Update the goldens after the fixes and report the new render paths.

## Done means

Tests + analyze green, goldens regenerated, and a short list of what changed per item.
