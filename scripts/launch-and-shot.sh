#!/usr/bin/env bash
# Launch the installed app on gigapc's Wayland session and grab a grim screenshot.
set -euo pipefail
OUT="${1:-/home/ubuntu/.hermes/cache/scratch/real-shots/room2.png}"
REMOTE=/tmp/wt-shot-$(date +%H%M%S).png

ssh -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc thecount@100.85.230.19 'bash -s' <<'R'
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
setsid ~/.local/opt/watch-together/watch_together > /tmp/wt-run.log 2>&1 < /dev/null &
sleep 9
tail -3 /tmp/wt-run.log
R

ssh -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc thecount@100.85.230.19 "bash -lc 'export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1; grim $REMOTE && ls -lh $REMOTE'" || \
ssh -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc thecount@100.85.230.19 "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1; grim $REMOTE && ls -lh $REMOTE"

scp -q -o BatchMode=yes -i /home/ubuntu/.ssh/clawn_gigapc "thecount@100.85.230.19:$REMOTE" "$OUT"
echo "saved: $OUT"
