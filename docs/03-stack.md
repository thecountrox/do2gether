# Stack decision (locked 2026-11-07)

| Layer | Choice | Why |
|---|---|---|
| Room server | **Rust** (axum + tokio) | The thing that must not flake. Shared protocol crate, one binary to deploy, no runtime. |
| Protocol | Rust crate `wt-protocol` + JSON Schema | Schema is canonical; the crate is the Rust view of it. Flutter reads the schema. |
| Desktop/mobile client | **Flutter + media_kit** | One UI on Linux, Windows, Android; libmpv everywhere. |
| Browser extension | **TypeScript** | YouTube and YTM remote control; shares generated types from the schema. |
| Discord bot | **TypeScript** (discord.js) | Iteration speed on slash commands and component embeds; a thin client of the room server. |
| Voice/chat | Discord | Not ours to build. |

## Why Rust for the core, TypeScript for the edges

The server is long-lived, holds room state and must be boring: Rust buys memory safety and a single static binary. The extension and bot are short-lived, event-driven and change weekly: TypeScript buys speed and shares the same generated schema types. Nothing is gained by making the bot Rust; nothing is risked by making the server TypeScript either — but the owner picked Rust, and the protocol boundary keeps that reversible.

## Discord bot responsibilities

- OAuth `identify` + guild membership; join tokens minted by the room server.
- Bind a room to a voice channel; gate control on being in the call.
- Live now-playing card with buttons (play/pause/skip/queue).
- Presence: who is in the call, who has the app, who is diverged.
- Never renders media; never proxies audio.

## Build notes for this host

- Rust debug builds only for tests; fat LTO OOMs here.
- Keep the dependency set small: axum (ws), tokio, serde, serde_json, hmac, sha2, base64, rand.
- The TypeScript server stays in `server/` as the reference implementation until the Rust server passes parity, then it is marked deprecated.
