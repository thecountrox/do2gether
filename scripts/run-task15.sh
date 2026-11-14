#!/usr/bin/env bash
# Detached run of the TASK15 Flutter UI implementation via Claude Code (Opus 5.5 through gigapc).
set -u
cd /home/ubuntu/watch-together || exit 1

KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i /home/ubuntu/.ssh/clawn_gigapc \
  thecount@100.85.230.19 \
  'sed -n "/^access:/,/^management:/p" ~/.cli-proxy-api/config.yaml | grep -oE "sk-[A-Za-z0-9_-]+" | head -1')

if [ -z "${KEY:-}" ]; then
  echo "FATAL: could not read proxy key from gigapc" > /home/ubuntu/watch-together/cc_task15.status
  exit 1
fi

export ANTHROPIC_BASE_URL=http://100.85.230.19:8317
export ANTHROPIC_API_KEY="$KEY"
export ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-5-5

claude -p 'Read TASK15.md and the approved boards in docs/design (home.html, room.html, room-ready.html and their pngs). Implement the desktop UI in app/ exactly as TASK15.md specifies. Keep protocol/clock/room_client/player behaviour. Run flutter analyze, flutter test and flutter build linux --debug with the documented nix env until green. Do not stop at a plan. Report files, tests, build path and any 1:1 gaps.' \
  --model claude-opus-5-5 --max-turns 80 \
  --allowedTools 'Read,Write,Edit,Bash' \
  --output-format json \
  > /home/ubuntu/watch-together/cc_task15.json 2> /home/ubuntu/watch-together/cc_task15.err

echo "exit=$?" > /home/ubuntu/watch-together/cc_task15.status
