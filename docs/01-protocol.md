# Room protocol — human summary

Canonical definition: `protocol/room.schema.json`. This file explains intent; if they disagree, the schema wins.

## Envelope

```json
{ "v": 1, "t": "<type>", "room": "<id>", "seq": 42, "ts": 1762500000000, "from": "<client id>", "id": "<optional request id>" }
```

- `v` protocol version. Unknown major → refuse with `reject`.
- `seq` monotonic per room; receivers drop state older than the newest they hold.
- `ts` is the sender's *server-time* estimate, never wall time.

## Messages

| Type | Direction | Purpose |
|---|---|---|
| `hello` | client → server | proto, client id/name/version, capability strings |
| `welcome` | server → client | full snapshot (`rev`, playback, queue, presence) + `server_now` |
| `clock_ping` | client → server | `ping_id`, `t0` |
| `clock_pong` | server → client | `ping_id`, `t0`, `t1` (receive), `t2` (send) |
| `intent` | client → server | `play`, `pause`, `seek`, `queue_add`, `queue_remove`, `skip` — a request, never truth |
| `state` | server → all | authoritative `{rev, playback, queue}` |
| `report` | client → server | observed `{offset_ms, rtt_ms, drift_ms, source}`; never broadcast |
| `presence` | server → all | join/leave |
| `event` | server → all | ephemeral activity events, never replayed |
| `reject` | server → client | `{code, message, req_id?}` |

## Playback anchor

```json
{ "item_ref": "file:sha256p:...", "anchor_server_ms": 1762500000000, "position_ms": 42000, "rate": 1, "paused": false }
```

Position at any moment: `paused ? position_ms : position_ms + (server_now() - anchor_server_ms) * rate`.

Play, pause and seek all rewrite the anchor rather than sending positions. Late joiners, reconnects and slow clients derive the same answer from the same anchor.

## item_ref grammar

- `file:sha256p:<size>:<first32hex>:<last32hex>` — partial hash: size + SHA-256 of first 4 MiB + SHA-256 of last 4 MiB.
- `yt:<videoId>` — YouTube via the official IFrame API (extension).
- `ytm:<videoId>` — YouTube Music, remote-controlling the user's own player (extension).
- `subsonic:<serverId>/<trackId>` — host-streamed library.

The algorithm is inside the ref, so a future full-hash or BLAKE3 ref is additive, not a migration.

## Clock

Four-timestamp ping, median of at least 8 samples:

```text
offset = ((t1 - t0) + (t2 - t3)) / 2
rtt    = (t3 - t0) - (t2 - t1)
```

One-way latency is assumed `rtt / 2`. The clock module exposes `ingest()`, `serverNowMs()`, `offsetMs`, `rttMs`, `uncertaintyMs` and knows nothing about routing.

## Versioning from commit one

- `v` in the envelope and `proto` in `hello`.
- `item_ref` grammar (above).
- Capability strings in `hello` (`player:mpv`, `source:ytm`, `transport:ws`).
- Activity ids as `type@schema_version` once activities exist.
- Time is int64 milliseconds of server time everywhere.
