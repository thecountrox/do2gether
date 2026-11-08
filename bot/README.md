# Watch Together Discord bot

From `bot/`, run `npm install`, `npm test`, `npx tsc --noEmit`, `npm run build`, then `npm start`.
For a gateway connectivity check, run `node dist/index.js --smoke` (exits within 20 seconds).

Configure `DISCORD_TOKEN` (bot login), `DISCORD_APP_ID` (application ID), `WATCH_SERVER`
(HTTP base URL of the room server) and `WT_BOT_TOKEN` (server Bearer credential).
When `DISCORD_TOKEN` is unset, the bot reads `../deploy/discord-bot.env` automatically.
Enable the Guild Voice States gateway intent, and grant the bot permission to send messages,
embed links, register commands and DM users. Guild commands are registered at startup.

Use the built-in text chat attached to a voice channel:

- `/room create` creates a room for callers in that voice channel and posts its card.
- `/room invite @user` sends a join token to a user in the call by DM (ephemeral fallback).
- `/room status` shows the room, members, playback and drift privately.
- `/room lock` and `/room unlock` change joining permissions (host only).
- `/room close` deletes the room (host only).

There is **one active room per voice channel**. Bindings and cards are in memory for rooms
created by this bot process; after a bot restart, create a new binding. Cards update every
10 seconds, stopping after 30 minutes without members. The shared card has a Status button;
the Close button appears only in the host's private status view.
