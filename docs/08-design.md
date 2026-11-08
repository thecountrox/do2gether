# Design: watch-together v2

Style: **Noir Cinema** — a dark room with warm light. Near-black surfaces, one warm accent that
reads like a projector glow, one cool accent that means "live". Big type, generous space, rounded
glass controls, nothing that looks like a settings form.

## Tokens

```
bg        #0A0B0D   canvas
surface   #121418   cards, bars
surface2  #1A1D22   hover, inputs
stroke    #FFFFFF14 hairline
text      #F5F7FA
muted     #98A1AC
accent    #FFB25B   primary action, focus, "projector"
live      #5BE3C8   sync ok, presence
warn      #FFC857
danger    #FF6B6B

radius    card 24, control 16, pill 999
space     4 8 12 16 24 32 48
type      display 40/44 w700 -1.0
          title   24/30 w650 -0.4
          body    15/22 w450
          caption 12/16 w500 +0.2 uppercase tracking
motion    180ms easeOutCubic; press scale .98; sync dot pulse 2s
```

No pure black, no pure white, no blue-purple gradients. One accent per screen: amber acts, teal
informs.

## Flow (the "sexy" part)

1. **Home** — one primary action: *Join a room*. Paste the invite link; it parses. No server form
   visible. A quiet line at the bottom: `Server watch.… · Change`. Secondary, ghost: *Start a room*.
2. **Start a room** — one tap. A sheet slides up: big room code, invite link, `Copy link`, and
   `Enter room`. No intermediate form, no token shown.
3. **Join** — paste link or code. Manual room+token lives behind `Enter code manually` (collapsed,
   last resort). Inline errors, never a snackbar for validation.
4. **Room** — the player is the page. Chrome floats over it:
   - top: back, room code chip (tap copies), sync chip (`● 12 ms`, teal when in sync, amber when
     correcting, red when divergent), people avatar stack.
   - center: empty state `Open a file to watch together` + amber `Open file`. Never a dead black box.
   - bottom: glass bar — play/pause, −10, +10, time, volume, fullscreen. Disabled (40% opacity) until
     a file is open.
   - wide screens: right rail with `In this room` and `Queue`; narrow: bottom sheet from the people
     button. Same data, different container.
5. **Waiting for host file** — if `item_ref` doesn't match the local file, the player area shows that
   state with an amber outline, not an error toast.
6. **Disconnected** — a slim banner under the top bar: `Reconnecting…`; controls disabled but the
   room stays visible.

## Component inventory

`WtScaffold` (bg + max-width column), `WtButton` (filled amber / ghost / danger), `WtField`
(label-less, 56px, surface2, 16 radius, focus ring amber 24% 2px), `WtChip`, `WtAvatar` (initial,
deterministic hue from user id), `WtAvatarStack`, `WtGlassBar`, `WtSheet` (24 top radius, drag
handle), `WtEmptyState`, `WtSyncDot` (pulsing), `WtCode` (large mono room code).

## Copy

- Home title: `watch together`
- Sub: `One screen. Same moment.`
- Primary: `Join a room`
- Secondary: `Start a room`
- Invite sheet: `Room ready` / `Send this link` / `Copy link` / `Enter room`
- Empty player: `Open a file to watch together` / `Open file`
- Waiting: `Waiting for the host's file`
- Sync chip: `12 ms` / `syncing` / `off`

## Responsive

Breakpoint 900px. Desktop centres a 560px column on Home; the room fills the window with a 320px
rail. Phone: full-bleed player 16:9, controls at the bottom safe area, rail becomes a sheet.

## Done

Join, create-sheet, empty room, and room-with-controls all look like the same product. No form-looking
screens. Every interactive element has a hover/press state. Screenshots from the emulator at
1080×2400.

---

# Direction 2 — Candy Stage (current, supersedes Noir Cinema)

Playful, glossy, a little arcade. A rhythm-game vibe without copying any game's characters, logos or
assets. The player is still the hero; decorations never sit over video.

## Tokens

```
bg        #170F2B   deep plum, radial pink/cyan washes at the corners
surface   #FFFFFF10 gradient card over #2A1A4A
border    #FFFFFF22 2px, inner top highlight #FFFFFF44
text      #FFF8FF
muted     #C9B6EA
pink      #FF5FA2
violet    #8B5CF6
cyan      #5CE1E6   live / sync
star      #FFE066

radius    card 28, control 20, chip 999
type      display Baloo2 w800-900, -0.5 tracking
          body    Nunito w500-800
motion    press scale .96 (120ms), sheet 240ms, sparkle drift 12s loop
```

Fonts are bundled from Google Fonts (OFL): `Baloo2-Variable.ttf`, `Nunito-Variable.ttf`.

## Rules

- Primary CTA: pink→violet→amber gradient, dark text, top inner highlight, soft pink glow.
- Secondary: glass fill, 2px light border, no glow.
- Chips are sticker-like: 2px border, slight tilt (≤1.5°), uppercase captions.
- Avatars: candy gradients, 2px white ring, deterministic by user id.
- Player frame: 24 radius, 2px light border, subtle vignette; empty state gets a glowing cyan "+"
  button.
- Sparkles: 8-14 small stars in the background, drifting slowly; never over the video surface; off
  when `MediaQuery.disableAnimations`.
- No pure black. No flat single-color buttons. No grey Material defaults.
