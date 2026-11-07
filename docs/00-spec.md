# watch-together — v1 spec (locked 2026-11-07)

One room, two modes: watch and listen. The room is the product; every source is a `PlayerAdapter`, every feature an `Activity`, every byte path a `Transport`.

## Owner decisions

- **Wedge:** both modes at equal weight — video nights and listening rooms in one room type.
- **Sources (all, sequenced):** local video files → Navidrome/Subsonic → YouTube (extension) → YouTube Music (extension, spike-gated).
- **Discord:** full concierge in v1 — OAuth, presence, voice-state gating, join tokens, queue and playback from Discord.
- **Guest prep:** install the app + Discord login is acceptable. No file distribution.
- **Later activities:** shared browser, stats/recaps, room games. No netplay in v1.
- **Client:** Flutter + media_kit (Linux, Windows, Android). The app never hosts a webview; web sources live in a TypeScript browser extension.
- **Server:** TypeScript on Node 24, `ws` for sockets. Shares the protocol schema with `/ext`.

## Non-goals

- Content distribution: no P2P seeding, relay, transcoding, or "get everyone the file".
- DRM services (Netflix/Prime/Hotstar) and Spotify sync.
- Standalone voice or chat. Discord owns both.
- A Discord Activity that renders media. At most a remote.

## Source of truth

`protocol/room.schema.json` defines every message. Code is generated or written against it; no ad-hoc message shapes.
Unknown message types are ignored, unknown fields preserved. `v` is the protocol version; `item_ref` grammar is versioned inside the ref.

## Milestones

- **M1** room server + protocol + clock + local video desktop. Exit: two friends watch a film synced.
- **M2** Discord bot/OAuth/join tokens, Navidrome desktop. Exit: weekly listening runs from Discord.
- **M3** extension (YouTube first, then YTM spike), Android Navidrome player + controller.

## Sync rules

- Server-authoritative playback anchor `{item_ref, anchor_server_ms, position_ms, rate, paused}`. Clients derive position from `server_now()`.
- Video: ignore drift < 250 ms, rate-nudge 250 ms–2 s, seek > 2 s. Music: 100–150 ms, seek/buffer-restart, never tempo-bend.
- Every control action increments `seq`; receivers drop stale events.
- Report telemetry every 10 s: `{offset_ms, rtt_ms, drift_ms, source}` with `activity_id: null`.

## Hashing

Local files: partial hash — size + SHA-256 of first 4 MiB + SHA-256 of last 4 MiB. Full hashing a multi-GB file on a phone is too slow. Ref form: `file:sha256p:<size>:<first32hex>:<last32hex>`.
