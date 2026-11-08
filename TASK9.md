# TASK: Discord bot v1 (discord.js)

Build `bot/` — a TypeScript Discord bot that acts as the room concierge. It is a client of the room
server over HTTP; it never touches media, voice audio, or the WebSocket protocol.

## Project

```
bot/
  package.json        type: module; deps: discord.js, dotenv; dev: typescript, tsx, @types/node
  tsconfig.json       NodeNext, strict
  src/index.ts        client bootstrap, command registration, interaction routing
  src/roomApi.ts      typed client for the room server (create/token/get/patch/delete/stats)
  src/voice.ts        voice-channel gate helpers (pure functions, unit-testable)
  src/card.ts         embed/component builders (pure, unit-testable)
  test/*.test.ts      node:test
```

Env (already in `deploy/discord-bot.env`): `DISCORD_TOKEN`, `DISCORD_APP_ID`, `WATCH_SERVER`,
`WT_BOT_TOKEN`. Load with dotenv from `../deploy/discord-bot.env` when `process.env.DISCORD_TOKEN`
is unset; never log any of these values.

## Commands (guild-scoped, registered on ready for the guilds the bot is in)

`/room create` — must be used in a text channel attached to a voice channel where the caller is
connected. Calls `POST /rooms {host_id, host_name, guild_id, voice_channel_id}`, stores the room
bound to that voice channel (one active room per voice channel), posts the card, replies ephemeral
with the room id.

`/room invite @user` — caller must be in the bound voice channel; target must be in the same voice
channel. Calls `POST /rooms/{id}/tokens {user_id, user_name}`, DMs the target:

```
Room: <room_id>
Token: <token>
Open the app, paste both, or run:
wt-play --server <WATCH_SERVER> --room <room_id> --token <token> --file <path>
```

If the DM fails (closed DMs), reply ephemerally with the same text.

`/room status` — ephemeral embed: room id, host, members, rev, now playing `item_ref`, drift p50/p95,
locked/controls.

`/room lock` / `/room unlock` — host only; `PATCH /rooms/{id} {locked}`.

`/room close` — host only; `DELETE /rooms/{id}`, clear the channel binding.

## Card

One message per room, edited every 10 s while the room has members (stop after 30 min idle):
- Title: the voice channel name
- Fields: `host`, `members n/50`, `now playing` (or "nothing yet"), `drift p95`
- Components: `Status` (secondary, ephemeral), `Close` (danger, host only; hidden for others)
- No media, no link buttons that pretend to join.

## Voice gate (pure)

```ts
// returns null when allowed, or a human reason when not
canCreate(member, channel): string | null
canInvite(caller, target, channel): string | null
```

Rules: caller must be connected to the bound voice channel; target must be connected to the same
channel; bots cannot be invited; a user already in presence is a no-op message, not an error.

## Smoke mode

`node dist/index.js --smoke` connects, waits for `ready`, prints `SMOKE_OK guilds=<n>` and exits 0
within 20 s. This is how CI verifies the token without running a gateway forever.

## Tests

- `voice.ts`: caller not connected, wrong channel, target not connected, target is a bot, all-good.
- `card.ts`: member count formatting, now-playing fallback, Close button only for host.
- `roomApi.ts`: URL building and error mapping with a stubbed fetch.
- No test may require the network or a real token.

## Done means

`npm install && npm test` green, `npx tsc --noEmit` clean, `node dist/index.js --smoke` prints
`SMOKE_OK guilds=1`, and `bot/README.md` documents commands, env, and the one-room-per-voice-channel
rule. Report files, tests, smoke output, and anything deferred.
