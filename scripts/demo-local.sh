#!/usr/bin/env bash
# Two real mpv clients, one local server: creates a room, joins, plays, seeks, pauses.
# Prints the drift lines from both clients at the end.
set -euo pipefail

BIN=${BIN:-/home/ubuntu/watch-together/rust/target/debug}
SERVER=${SERVER:-http://127.0.0.1:8787}
FILE=${FILE:-/tmp/wt-test.mp4}
WORK=$(mktemp -d /tmp/wt-demo.XXXXXX)

cleanup() { exec 3>&- 4>&- 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkfifo "$WORK/a.in" "$WORK/b.in"

"$BIN/wt-play" --server "$SERVER" --create --headless --name ann --file "$FILE" <"$WORK/a.in" >"$WORK/a.log" 2>&1 &
A=$!
exec 3>"$WORK/a.in"

for _ in $(seq 100); do grep -q '^share: ' "$WORK/a.log" && break; sleep 0.1; done
ROOM=$(sed -n 's/^room: //p' "$WORK/a.log" | head -1)
TOKEN=$(sed -n 's/^share: .*--token \([^ ]*\).*/\1/p' "$WORK/a.log" | head -1)
if [ -z "$ROOM" ] || [ -z "$TOKEN" ]; then echo "FAILED: no room/token"; cat "$WORK/a.log"; exit 1; fi
echo "room=$ROOM"

"$BIN/wt-play" --server "$SERVER" --room "$ROOM" --token "$TOKEN" --headless --name bob --file "$FILE" <"$WORK/b.in" >"$WORK/b.log" 2>&1 &
B=$!
exec 4>"$WORK/b.in"

sleep 2
echo play >&3
sleep 12
echo "seek 30000" >&3
sleep 10
echo pause >&4
sleep 3
echo play >&4
sleep 8
echo q >&3
echo q >&4
wait "$A" || true
wait "$B" || true

echo
echo "--- ann drift (last 6)"
grep -E 'drift=' "$WORK/a.log" | tail -6
echo "--- bob drift (last 6)"
grep -E 'drift=' "$WORK/b.log" | tail -6
echo
python3 - "$WORK" <<'PY'
import re, sys, pathlib
work = pathlib.Path(sys.argv[1])
for name in ("a", "b"):
    ds = [int(m.group(1)) for m in re.finditer(r"drift=([+-]?\d+)", (work / f"{name}.log").read_text())]
    if ds:
        ds_abs = sorted(abs(d) for d in ds)
        print(f"{name}: samples={len(ds)} max_abs={max(ds_abs)}ms p95={ds_abs[int(len(ds_abs)*0.95)-1]}ms")
PY
