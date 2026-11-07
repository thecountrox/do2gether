# Discord bot contract

The bot is a client of the room server, not a second backend. It owns Discord-specific concerns:
OAuth, membership, voice state, and the card in the text channel. It never renders media, never
proxies audio, and never talks to mpv.

## Flows

**Create a room from a voice channel**

```
/room create            (in a voice channel's text chat)
  bot: checks the caller is in the voice channel
  bot: POST /rooms {host_id: discord_id, host_name, guild_id, voice_channel_id}
  bot: posts the room card with a Join button and the room code
```

**Invite someone who is in the call**

```
/room invite @user
  bot: verifies the target is in the same voice channel
  bot: POST /rooms/{id}/tokens {user_id, user_name}
  bot: DMs the join link (or ephemeral reply)
```

**Join**

`Join` button → `https://host/join/<token>` → app/extension deep link → WS connect.
Desktop can also use Rich Presence's join secret; Android uses the link.

**Now playing**

The bot subscribes to `GET /stats` (2 s poll) or holds its own WS observer connection; edits one
message in place with `rev`, members, and playback summary. Edits are rate-limited to one per 3 s.

**Controls**

Buttons send `PATCH`-free intents through a bot-side observer socket using the host's identity only
if the host opted in; otherwise the card is read-only and control stays in the app. This is deliberate:
a Discord button must not bypass the host gate.

**Voice gating**

`GUILD_VOICE_STATES` lets the bot read `member.voice.channel_id`. Only members in the room's bound
voice channel are offered tokens. Anyone else gets "join the call first".

## Slash commands (v1)

| Command | Scope | Effect |
|---|---|---|
| `/room create` | guild | create + bind to the current voice channel |
| `/room invite @user` | guild | mint a token, DM the link |
| `/room status` | guild | ephemeral: rev, members, drift p95 |
| `/room close` | host | DELETE the room |
| `/room lock` / `/room unlock` | host | PATCH locked |

## Card shape

Component V2 container: room name, `host`, `members 4/50`, now-playing line, buttons
`[Join] [Status] [Close]` (Close only for the host). No media embeds — the card links, it does not play.

## Implementation notes

- TypeScript, `discord.js`, one process, one `DISCORD_TOKEN`.
- Bind room ↔ `{guild_id, voice_channel_id}`; only one active room per voice channel.
- The bot stores nothing; the room server's SQLite is the source of truth.
- Bot restarts re-read `/rooms` from the server (add a list endpoint if it becomes necessary; today
  the bot only needs rooms it created in-process).
- The Hermes/Clawn adapter owns its own slash-command tree; run this bot as a separate application
  unless the command names are namespaced to avoid the reconcile behaviour.

## Blocked on the owner

- A bot application + token and the guild id.
- A decision: separate bot, or a Clawn plugin with namespaced commands.
