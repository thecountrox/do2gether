# watch_together — Flutter client (desktop v1)

Joins a room, opens a local file, and follows the room anchor. Linux desktop is the only
platform wired so far; `app/linux/` is the only runner directory.

## Build and run (this host)

Flutter comes from nix, the GTK/mpv stack from apt, so the build and the run each need a nudge:

```bash
nix shell nixpkgs#flutter -c bash -c '
  cd app
  export CC=/usr/bin/clang CXX=/usr/bin/clang++
  export LDFLAGS="-L/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib \
    -Wl,-rpath,/nix/store/3g2mlwyf1wkiwkjcv86hi9j9d73r9xz9-pcre2-10.49/lib"
  flutter build linux --debug
'

# running needs the system library path because libflutter comes from nix
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu ./build/linux/arm64/debug/bundle/watch_together
```

On a normal Flutter install (system SDK, system clang) neither the LDFLAGS nor the LD_LIBRARY_PATH
is needed. The pcre2 flag exists because nix glib 2.88 wants pcre2 10.47+ while the system linker
finds an older one.

## What it does

- **Join screen** — server URL (defaults to the deployed `https://watch.…sslip.io`), room id, token,
  display name; `Create room` calls `POST /rooms`.
- **Room screen** — WebSocket with `hello`/`welcome`, a 10-sample median clock, presence, `rev`/
  `seq`, and controls: open file, play, pause, ±10 s.
- **Player** — `media_kit`; opening a file computes `file:sha256p:<size>:<first32>:<last32>`,
  applies the room anchor (ignore < 250 ms, rate ±3 % up to 2 s, seek beyond), reports drift every
  5 s. A different `item_ref` shows "waiting for host file" instead of playing the wrong thing.

## Tests

```bash
nix shell nixpkgs#flutter -c bash -c 'cd app && flutter test'
```

26 tests: protocol roundtrip and item_ref grammar, clock median/outliers, `positionAt`, drift bands,
file hashing (small/empty/large), join-screen validation.

## Known limits

- Desktop only; Android needs the SDK and a foreground service for background audio.
- No queue UI yet, no subtitle controls, no audio-device picker.
- The app and the `wt-play` CLI can share a room file only if both hash identically — they do — but
  pairing them is manual.
