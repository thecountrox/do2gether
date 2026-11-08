# TASK: user-bound tokens + join page

Roadmap item 1, server half. Read `docs/07-roadmap.md` and `docs/05-backend-architecture.md`.

## Token claims

Extend the join token payload from `{room, exp}` to `{room, exp, sub?}` where `sub` is the user id the
token is bound to. The HMAC covers `room:exp:sub` (empty string when absent), so existing formatting
stays `<base64url(payload)>.<base64url(sig)>`.

- `POST /rooms {host_id, host_name}` mints a token with `sub = host_id`.
- `POST /rooms/{id}/tokens {user_id, user_name}` mints a token with `sub = user_id`.
- Tokens without `sub` stay valid (manual/host use), keep the current lifetime.
- `verify_token` returns the claims; the WS layer keeps `expected_sub` for the connection.
- On `hello`, when the token has a `sub` and `hello.client.id != sub`, close the socket with
  **4001** and reason `identity mismatch`, before joining presence. No state change.

## Join page

`GET /join/{token}` — public, no auth, HTML, 200:

- Decodes the token without verifying (show what it says) **and** verifies signature/expiry.
- Valid: shows room id, "Open the watch-together app" button linking to
  `watchtogether://join?room=<room>&token=<token>`, a copy button for room id and token, and a line
  "or run: wt-play --server <base> --room <room> --token <token> --file <path>".
- Invalid/expired: 400 HTML with "this link expired" and a hint to run `/room invite` again.
- No external assets, no scripts beyond a tiny inline copy handler, dark styling, mobile-first.
- `<base>` must come from the `Host` header scheme (https when `X-Forwarded-Proto: https`), not a
  hardcoded IP.

## Tests

1. Token roundtrip: sub present/absent; tampered sub fails; expired fails.
2. `POST /rooms` token has `sub = host_id`; bot token endpoint has `sub = user_id`.
3. WS: token with `sub=ann` + `hello` id `bob` → close 4001, no presence broadcast; `hello` id `ann`
   → welcome.
4. Unbound token still joins with any `hello` id.
5. `GET /join/<valid>` 200 contains room id and the `watchtogether://` link; `GET /join/<garbage>` 400.
6. Existing 59 tests updated for the verify signature change.

## Done means

`cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check` green, plus a curl
transcript: create room → `GET /join/<token>` → head of the HTML, and a WS reject with the wrong id.
