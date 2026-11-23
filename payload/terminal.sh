#!/bin/bash
# The browser terminal behind one tile on the apps dashboard. Not a command: lite-terminal@USER.service starts it
# as that Linux user, with PORT, TOKEN, TITLE and HINT from /etc/lite/terminal-USER.env (root only).
# It runs stock ttyd, which shows a normal login shell of that user in the browser:
#   - it listens on a private socket, /run/lite-terminal/USER/ttyd.sock, that only this user and Caddy can open;
#     Caddy answers https on PORT over Tailscale only, so the firewall's device list decides who gets in
#     (see payload/https.sh) and no other user or app on this server can reach it
#   - the page lives under a long random path that only the tile's link knows
#   - -O refuses a connection started by another website
set -u
cd "$HOME" || exit 1
# the socket gets the folder's group (caddy) and no rights for anyone else; the shell gets the usual 022 back
umask 007
exec /opt/lite/bin/ttyd -i "/run/lite-terminal/$USER/ttyd.sock" -b "/$TOKEN" -W -O -t "titleFixed=$TITLE" \
  bash -c 'umask 022; printf "%s\n\n" "$0"; exec bash -l' "$HINT"
