# Design process (locked)

**Design authority: Claude Opus 5.5, working from the `claude-design` skill.**
Clawn does not pick palettes, layouts, type scales or component shapes. Clawn's job is to:

1. Write the brief: product, flow, constraints, what is already settled.
2. Supply evidence: real screenshots, server capabilities, font licensing limits.
3. Run the critique loop: render the board, describe concrete flaws, ask Opus to fix them.
4. Verify the implementation against the board and report differences.

Opus produces: the board (HTML), the design rationale, and — when the board is accepted — the Flutter
UI implementation via Claude Code. If Claude Code is unavailable, OpenCode ports the accepted board
mechanically; Opus still owns every visual decision.

## Doctrine Opus must follow (from `claude-design`)

- **Surface first.** Name the archetype before any token: Home = Decide/Configure, Room ready =
  Configure, Room = Operate. No centered hero stacks outside Decide surfaces.
- **No slop:** no generic three-card grid, no unearned glass, no rainbow palette, no emoji-as-icon, no
  fake metrics, no default Inter. Score the artifact with the ten-tell diagnostic before delivery.
- **Composition over decoration.** If hierarchy is wrong, re-lay-out; do not recolor.
- **Type is the lever.** Choose deliberately; verify contrast and line fit by measurement.
- **Motion clarifies state**, respects `prefers-reduced-motion`.
- **Verify before "done":** file exists, renders, primary viewport checked, no console errors.

## Hard constraints we hand Opus

- Fonts: M PLUS Rounded 1c only (OFL). The real Project SEKAI face (FOT-Rodin) is commercial and must
  not be referenced or bundled.
- No game characters, logos, or copied layouts from any game.
- Flow: Join (link/code) → Room ready (host) → Room (player-first).
- Player video is 16:9 letterboxed; controls are labelled; sync/live is cyan; one gradient CTA per
  screen.
- Mobile frames 390x844; Android + desktop.

## Current decision

v3 flow + v2 visual system (deep plum, saturated pink→violet gradient, glow, glossy key-caps). v2 is
the styling reference the owner approved; v3 is the structure. v3's pastel palette is rejected.
