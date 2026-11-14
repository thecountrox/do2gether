# Goal: desktop v1 of watch-together, shipping

**Objective.** A Linux + Windows desktop app where a Discord-invited group joins a room, opens the
same media (local file or Jellyfin direct-play), and stays in sync; the UI matches the approved
boards (`docs/design/`). Phone is a future companion remote, not part of v1.

## Definition of done — status

| # | Criterion | State |
|---|---|---|
| 1 | Flutter desktop UI against the boards (Home split, Room ready dialog, Room player+rail) | **done** (`a091b63`, `67df04b`) |
| 2 | analyze clean, tests green, Linux + Windows artifacts | **done**: 99 tests, both builds |
| 3 | Visual proof from the real build, not a mockup | **done**: `grim` window capture + goldens at 1440x900 and 856x1038 |
| 4 | Sync proof: two clients, measured drift | **done**: p95 0 ms, max 1 ms (simulated players, deployed server) |
| 5 | Room server + bot deployed and healthy | **done**: `wt-server`, `wt-bot`, `/health` ok |
| 6 | Installable Linux bundle published and installed on gigapc | **done**: `do2gether-linux-x64.tar.gz` |
| 7 | Everything committed; docs reflect shipped state | **done** |

**Windows artifact:** built by CI (`windows` workflow in `thecountrox/do2gether`), mirrored to the
files host after each run.

## Where things run

| Thing | Where |
|---|---|
| Source | `thecountrox/do2gether` (private); local `~/watch-together` |
| Room server | `watch.141.253.97.15.sslip.io`, systemd `wt-server`, SQLite `data/wt.db` |
| Discord bot | `watch-together#6690`, systemd `wt-bot` |
| Linux build + screenshot | `scripts/desktop-shot.sh` (builds on gigapc, installs, `grim`) |
| Windows build | GitHub Actions `windows.yml` |
| Drift check | `scripts/drift-check.py` (host `--create`, guest token via bot API) |
| Live Opus view | `https://opus.141.253.97.15.sslip.io/` (auth `wt`) |
| Artifacts | `files.141.253.97.15.sslip.io/user_uploads/watch-together/` |

## Deliberately not in v1

- Jellyfin direct-play adapter (v1.1); local files only today.
- Phone player — the plan is a companion remote (join, transport, queue), no decoding.
- YouTube/YTM sources; the extension is a later track.
- Voice: Discord's, always.

## Next milestones

1. **v1.1 Jellyfin**: `jellyfin:<server>/<item>` refs, client-side direct play, no server egress.
2. **Join polish**: `do2gether://` deep-link handling so an invite opens the app prefilled.
3. **Rename pass**: ids/labels from `watch-together` to `do2gether` in one shot (bundle id, services,
   desktop entry) — after v1.1, so installs break once.
4. **Phone remote**: two screens, no player.

## Rules

- Opus owns design; Clawn briefs, verifies with real output, never restyles locally.
- No "done" without tool output: test counts, build paths, screenshots, curl transcripts.
