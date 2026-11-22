#!/bin/bash
# The browser terminal behind one tile on the apps dashboard. Not a command: lite-terminal@USER.service starts it
# as that Linux user, with PORT, TOKEN, TITLE and HINT from /etc/lite/terminal-USER.env (root only).
# It runs stock ttyd, which shows a normal login shell of that user in the browser:
#   - it listens on the server's Tailscale address only, so the firewall's device list decides who gets in
#   - the page lives under a long random path that only the tile's link knows
#   - -O refuses a connection started by another website
set -u
ip=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$ip" ] || { echo "no Tailscale address yet; trying again shortly"; exit 1; }
cd "$HOME" || exit 1
exec /opt/lite/bin/ttyd -i "$ip" -p "$PORT" -b "/$TOKEN" -W -O -t "titleFixed=$TITLE" \
  bash -c 'printf "%s\n\n" "$0"; exec bash -l' "$HINT"
