# TASK: reskin to "Candy Stage"

Apply Direction 2 in `docs/08-design.md` to the existing UI from TASK11. Layout and flow stay as they
are; this is a visual reskin plus the decorative layer. Do not change protocol, clock, room client or
player behaviour.

## Theme

- Rewrite `lib/theme.dart`: `ThemeData.dark` seeded with the Candy Stage palette, `fontFamily: Nunito`,
  headings explicitly `Baloo2`.
- Background: a `BoxDecoration` radial wash (pink 20% top-right, cyan 18% bottom-left) over `#170F2B`.
  Expose `WtBackground` in `widgets/chrome.dart` so Home and Room share it.
- Text theme maps: display → Baloo2 w900, title → Baloo2 w800, body → Nunito w500, caption → Nunito
  w700 uppercase +0.12em muted.

## Components (restyle, keep APIs)

- `WtButton`: filled = pink→violet gradient with a 12% white top highlight and pink glow shadow;
  ghost = 2px `#FFFFFF2B` border, glass fill; danger = coral gradient. Press scale .96, 120 ms.
  Sizes 56 and 44.
- `WtField`: 56px, `#FFFFFF10` fill, 2px `#FFFFFF22` border, 20 radius, inset shadow; focus border
  cyan 60% + 2px outer glow.
- `WtChip`: sticker styling, optional `tilt` (default 0, ±0.026 rad), uppercase label.
- `WtAvatar`: candy gradients (pink→amber, cyan→violet, violet→pink by hash), 2px white ring.
- `WtGlassBar`: 22 radius, `#FFFFFF14`, 2px border, inner highlight; the play button becomes a 40px
  gradient circle.
- `WtSheet`: 28 top radius, drag handle, `#2A1A4A` fill, 2px border, slide 240 ms.
- `WtEmptyState`: add the glowing cyan `+` circle above the text.
- `WtCode`: Baloo2 w900, 40px, letter-spacing 2.

## Decoration

- New `lib/widgets/sparkles.dart`: `WtSparkles` CustomPainter, 10 deterministic stars (seeded by
  room id or fixed), star glyphs/diamonds in `#FFE066` and white at 20-45% opacity, slow drift
  animation (12 s loop). Disabled when `MediaQuery.of(context).disableAnimations` is true. Placed
  behind content on Home and behind the player chrome (never over the video texture; wrap only the
  empty state, not `Video`).
- Home wordmark: `watch together` in Baloo2 w900 with a pink→cyan horizontal gradient and one
  sparkle. Keep the single-field + two-button flow exactly.
- Room: top chips and bottom bar restyled; player frame gets a 2px border + vignette overlay in the
  empty state only.

## Tests / checks

- `flutter analyze` clean, `flutter test` green (33 tests; update any style-coupled widget assertions).
- No overflow errors in the existing widget tests at 360×800 and 1280×800 (add a small pump test for
  Home at both sizes).
- Linux debug build with the documented CC/CXX/LDFLAGS.

## Done means

Report files, tests, build path, and any place where the reference image and this spec disagreed.
