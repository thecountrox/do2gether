#!/usr/bin/env bash
# Build the Flutter desktop app on gigapc (x86_64, real Wayland session), install it, launch it,
# and grab a real screenshot with grim. Prints the local path of the screenshot.
#
# gigapc's login shell is fish, so every remote step is piped into `bash -s` rather than quoted.
set -euo pipefail

SSH_CMD=(ssh -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc thecount@100.85.230.19)
SCP_CMD=(scp -q -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc)
OUT_LOCAL="${1:-/home/ubuntu/.hermes/cache/scratch/app-shot.png}"
STAMP=$(date +%H%M%S)
REMOTE_SHOT="/tmp/wt-shot-$STAMP.png"

echo "== sync sources"
cd /home/ubuntu/watch-together
tar czf - --exclude='app/build' --exclude='app/.dart_tool' --exclude='app/.gradle' app protocol \
  | "${SSH_CMD[@]}" 'mkdir -p ~/watch-together && tar xzf - -C ~/watch-together'

echo "== build release on gigapc"
"${SSH_CMD[@]}" 'bash -s' <<'REMOTE'
set -e
cd ~/watch-together/app
~/flutter/bin/flutter build linux --release 2>&1 | tail -3
REMOTE

echo "== install + launch"
"${SSH_CMD[@]}" 'bash -s' <<'REMOTE'
set -e
if [ -f /tmp/wt-app.pid ]; then
  kill "$(cat /tmp/wt-app.pid)" 2>/dev/null || true
  rm -f /tmp/wt-app.pid
fi
mkdir -p ~/.local/opt/watch-together
cp -a ~/watch-together/app/build/linux/x64/release/bundle/. ~/.local/opt/watch-together/
chmod +x ~/.local/opt/watch-together/watch_together
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
nohup ~/.local/opt/watch-together/watch_together > /tmp/wt-run.log 2>&1 &
echo $! > /tmp/wt-app.pid
sleep 8
hyprctl clients -j > /tmp/wt-clients.json
python3 - <<'PY'
import json
clients = json.load(open('/tmp/wt-clients.json'))
for c in clients:
    label = (c.get('class') or '') + (c.get('initialClass') or '')
    if 'watch_together' in label:
        print('window:', c.get('title'), '|', c.get('class'), '|', c.get('size'))
        break
else:
    print('window: NOT FOUND')
PY
echo "--- app log"
tail -5 /tmp/wt-run.log || true
REMOTE

echo "== screenshot"
"${SSH_CMD[@]}" 'bash -s' <<REMOTE
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
grim $REMOTE_SHOT
ls -lh $REMOTE_SHOT
REMOTE
"${SCP_CMD[@]}" "thecount@100.85.230.19:$REMOTE_SHOT" "$OUT_LOCAL"
echo "saved: $OUT_LOCAL"
