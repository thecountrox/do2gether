# TASK: library polish from the first real review

The library shipped and works (170 tests). A review of the rendered screen found four things worth
fixing, plus one open question. Small, visual, no model changes.

1. **The grid is too dense.** Seven cards across at 1440 is a filmstrip, not a library. Cap the card
   width (roughly 180–220 px) and let the column count fall out of the available width, with a sensible
   minimum and gutters that grow. At 856 two-to-three columns, at 1440 four-to-five. Never stretch a
   poster to fill odd space — centre the row instead.
2. **Two tabs look selected at once.** `This computer` renders as a filled pill while `Jellyfin` is
   pink-outlined; both read as active. One visual language: the selected tab is filled and high
   contrast, the rest are quiet outlines, disabled ones are muted with their `Soon` tag. Never fill an
   unselected tab.
3. **The search clear button floats outside the field.** It sits detached to the right of the search
   pill. Put the clear affordance inside the field (trailing icon), keep the `/` shortcut badge inside
   too, and let the field take the remaining width.
4. **`Play` collides with the card's caption bar.** The hover action overlaps the bottom metadata strip.
   Give the action its own zone: a scrim across the bottom of the poster with the actions above the
   title, or actions revealed on a full-card scrim. Nothing may cover the title or duration.
5. **Untested for real:** posters with a live Jellyfin. The goldens use a fake source, so they render
   placeholder gradients. Add one test against an injected source that returns a real `posterUrl` and
   assert an `Image` with that URL is built (do not hit the network in tests), and make the placeholder
   graceful: a poster that fails to load keeps the gradient + glyph rather than a broken-image box.

## Constraints

- No protocol, intent or Jellyfin API changes.
- Candy palette, existing widgets, no new packages.
- Update `library_1440.png` and `library_856.png` goldens; add one for the empty search state if cheap.
- `flutter test` green, `flutter analyze` no new issues, `flutter build linux --debug` passes.

Report: what changed per item, test count, golden paths.
