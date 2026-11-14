# Goal: desktop v1 of watch-together, shipping

**Objective.** A Linux + Windows desktop app where a Discord-invited group joins a room, opens the
same media (local file or Jellyfin direct-play), and stays in sync; the UI matches the approved
Noir/Candy boards (`docs/design/`). Phone is a future companion remote, not part of v1.

## Definition of done (desktop v1)

1. Flutter desktop UI implemented against `docs/design/home.html`, `room.html`, `room-ready.html` —
   split Home launcher, Room ready dialog, player-first Room with rail + dock.
2. `flutter analyze` clean, all tests green, `flutter build linux --release` and a Windows build
   artifact both exist.
3. Visual proof: a screenshot of the real Linux build, not a mockup, compared to the board.
4. Sync proof: two clients in one room, measured drift printed, within video tolerance (<250 ms).
5. Room server + bot deployed and healthy (`wt-server`, `wt-bot`, `/health`).
6. Installable Linux bundle published (tar.gz on the files host) and installed on gigapc.
7. Everything committed; `docs/` reflects the shipped state.

## Current state (2026-11-14)

| Item | State |
|---|---|
| Room server (Rust, SQLite, permissions, bot API, metrics) | shipped, 63 tests |
| Discord bot (`/room` commands, join links) | shipped, 8 tests |
| Design boards + brand SVGs | approved, committed in `docs/design/` |
| Flutter desktop UI rework (TASK15) | **in progress** by Opus via tmux `task15` |
| Linux release build | pending the UI pass |
| Windows build | **blocked** — needs `thecountrox/watch-together` repo or Administration grant |
| Sync proof after UI change | pending |
| Jellyfin source adapter | not started (v1.1) |

## Work order

1. Finish TASK15 (Opus) → verify `analyze`/`test`/build myself, not by self-report.
2. Deploy the Linux build to gigapc, launch on the real Wayland session, `grim` screenshot, diff
   against the board, send gaps back to Opus.
3. Re-run the two-client drift measurement against the deployed server.
4. Publish the Linux tarball; refresh the APK only if the UI changed materially.
5. Unblock Windows (owner creates the repo) → CI artifact.
6. Then v1.1: Jellyfin adapter, then phone remote (join + transport controls only).

## Rules

- Opus owns design decisions; Clawn briefs, verifies with real output, and never restyles locally.
- No "done" without real tool output: test counts, build paths, screenshots, curl transcripts.
- Live progress: https://opus.141.253.97.15.sslip.io/ (auth `wt`).
