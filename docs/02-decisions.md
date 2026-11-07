# Decisions after M1

These resolve the open points from the first coding pass. `docs/00-spec.md` and the schema remain canonical; this file records the reasoning.

## Revision vs sequence

- `rev` is the **content revision**: it increments only when playback or queue changes.
- `seq` is the **envelope sequence**: it increments on every server broadcast, including presence.

Presence is ephemeral and must not invalidate a client's cached playback, but clients still need a total order on the wire. Keeping the two counters separate is what lets a reconnect compare `rev` (do I need a new snapshot?) without treating a join/leave as a state change.

## Rejected intents

Silence is not acceptable for a control action a user pressed. A rejected intent gets `reject {code: "intent_rejected", message, req_id}` addressed to the sender, and no `state` broadcast. `req_id` echoes the intent's `id`.

## Presence identity

Presence is keyed by `user_id`, not by connection. A second connection from the same user increments a count and does not emit another `join`; `leave` is emitted only when the last connection for that user closes. Snapshot presence lists each user once.

## Room not found

A structurally valid token for a room that does not exist closes with `4004`. This is documented behaviour, not an error path to test around.

## Test command

`node --test --experimental-strip-types test/` treats the directory as a single module on Node 24 and fails. The working form is `node --test --experimental-strip-types 'test/**/*.test.ts'`.

## Deferred

- Token revocation and room expiry (rooms live in memory and vanish on restart).
- Rate limiting `POST /rooms`.
- Persistent rooms / reconnect across server restart.
