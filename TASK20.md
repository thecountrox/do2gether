# TASK: the queue must accept Jellyfin items too

Found by the owner: `QUEUE → Add` only opens the local file picker. `RoomScreen._addToQueue` calls
`widget.pickCopy()` and nothing else, so a room whose media lives on Jellyfin cannot queue anything —
even though the same screen already carries a working `pickJellyfin` picker for the now-playing copy.

## What to change

1. **`Add` becomes a choice.** Tapping `Add` opens a small menu with two entries:
   - `From this computer` → the existing `pickCopy()`
   - `From Jellyfin` → `pickJellyfin()`, hidden when that callback is null
   Do not add a second button to the rail header; a two-item menu keeps the row quiet.
2. **One path from there.** Both routes end in the same `queue_add` intent with the item's `item_ref`,
   and both record the display name and duration in `_known` so the row renders properly.
3. **Rows say where they came from.** Queue rows get the same `Jellyfin` / `Local file` source chip the
   now-playing row uses, derived from the ref (`jellyfin:` prefix), not from a stored flag that can
   drift.
4. **Same for the queue's empty-state hint** if it assumes a file: "Add the next episode…" should work
   for either source.

## Also close this, if the immersive-fullscreen task did not

An **always-visible** `Exit fullscreen` control in fullscreen (low contrast, never auto-hidden) plus a
`Show controls` toggle — the owner does not want to wait for chrome to fade back in. Check
`lib/room_view.dart` first; if TASK19 already added a persistent one, say so and skip.

## Constraints

- No protocol or intent changes (`queue_add` already takes any `item_ref`).
- Reuse existing menu/widget vocabulary.
- Widget tests: the menu offers both entries when a Jellyfin picker exists, only the file entry when it
  does not, and a Jellyfin-queued item reaches `onAddToQueue`'s send path with its ref intact (fake the
  client or assert the recorded `_known` entry).
- `flutter test` green, `flutter analyze` no new issues, `flutter build linux --debug` passes.

Report: files, how the menu is built, test count.
