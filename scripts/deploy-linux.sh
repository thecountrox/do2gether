#!/usr/bin/env bash
# Sync the working tree to gigapc, build the Linux release, install it, and register the
# do2gether:// invite scheme with the desktop so an invite link opens the app prefilled.
set -euo pipefail
KEY=/home/ubuntu/.ssh/clawn_gigapc
HOST=thecount@100.85.230.19
APP_NAME=do2gether

echo "== sync"
TAR=/tmp/do2gether-src.tgz
rm -f "$TAR"
tar czf "$TAR" --exclude=build --exclude=.dart_tool --exclude=rust/target -C /home/ubuntu/watch-together app
scp -q -o BatchMode=yes -i "$KEY" "$TAR" "$HOST:/tmp/do2gether-src.tgz"
ssh -o BatchMode=yes -i "$KEY" "$HOST" 'mkdir -p ~/watch-together && tar xzf /tmp/do2gether-src.tgz -C ~/watch-together && echo synced'

echo "== build + install"
ssh -o BatchMode=yes -i "$KEY" "$HOST" 'bash -s' <<'R'
set -e
export PATH="$HOME/flutter/bin:$PATH"
cd ~/watch-together/app
flutter build linux --release 2>&1 | tail -3
pid=$(cat /tmp/wt-app.pid 2>/dev/null || true)
[ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
sleep 1
rm -rf ~/.local/opt/watch-together
mkdir -p ~/.local/opt/watch-together
cp -a build/linux/x64/release/bundle/. ~/.local/opt/watch-together/
chmod +x ~/.local/opt/watch-together/watch_together
echo installed
R

echo "== register scheme"
ssh -o BatchMode=yes -i "$KEY" "$HOST" "bash -s -- $APP_NAME" <<'R'
set -e
name="$1"
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/$name.desktop <<EOF
[Desktop Entry]
Type=Application
Name=do2gether
Comment=Watch, listen and do things together
Exec=$HOME/.local/opt/watch-together/watch_together %u
Icon=video-display
Terminal=false
Categories=AudioVideo;Player;Network;
MimeType=x-scheme-handler/do2gether;x-scheme-handler/watchtogether;
StartupWMClass=watch_together
EOF
update-desktop-database ~/.local/share/applications 2>/dev/null || true
xdg-mime default $name.desktop x-scheme-handler/do2gether
xdg-mime default $name.desktop x-scheme-handler/watchtogether
echo "handler: $(xdg-mime query default x-scheme-handler/do2gether)"
R
echo done
