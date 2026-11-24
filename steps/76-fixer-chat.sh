#!/bin/bash
# Step 76 (TEST, see PLAN.md): the fixer on Matrix, so the owner can reach Pi from Element X when something breaks.
#   bridge   pi-matrix-bridge (MIT, stock Pi extension, fixed version): Element X supported, runs Pi without a
#            screen as a background service. Its encryption is switched off (its own "encryption": false), like
#            every chat here (step 75: Tailscale plus the owner's server is the boundary, Miguel's choice).
#   account  @fixer (made in step 75). Its sign-in token lives only in the fixer's own ~/.pi (mode 600).
#   who      only the owner. The bridge trusts the listed users; anyone else in a direct chat only gets a
#            6-digit code that is shown nowhere (the service's screen output is discarded), and group rooms are ignored.
#   service  lite-fixer-chat (Linux user fixer). The Fixer tile on the dashboard stays as the way in when chat is down.
# Idempotent; nothing secret is printed.
set -uo pipefail
BRIDGE_VERSION=${BRIDGE_VERSION:-0.5.0}
E=/etc/lite; MX=$E/matrix.env; U=fixer; H=/home/$U; CFG=$H/.pi/matrix-bridge.json
as() { sudo -iu $U bash -lc "$*"; }
getv() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
NAME=$(tailscale status --json 2>/dev/null | jq -r 'if .BackendState == "Running" then .Self.DNSName // "" else "" end' | sed 's/\.$//')
PW=$(getv $MX FIXER_PASSWORD)
[ -n "$NAME" ] && [ -n "$PW" ] || { echo "fixer chat: added once Matrix is set up (step 75)"; echo "STEP 76 OK"; exit 0; }
OWNER=$(getv $E/owner.env OWNER_USER); OWNER=${OWNER:-owner}
PORT=$(jq -r '.[] | select(.id=="matrix-conduit") | .port' $E/apps.json); HS=http://127.0.0.1:$PORT

# 1. the bridge, as a Pi package of the fixer
if ! as "pi list" 2>/dev/null | grep -q "pi-matrix-bridge@$BRIDGE_VERSION"; then
  as "pi install npm:pi-matrix-bridge@$BRIDGE_VERSION" > /var/log/lite-pi-matrix-install.log 2>&1 \
    || { tail -15 /var/log/lite-pi-matrix-install.log; echo "the Pi Matrix bridge did not install"; exit 1; }
fi
echo "bridge: $(as "pi list" 2>/dev/null | grep -o "pi-matrix-bridge@[^ ]*" | head -1)"

# 2. its own sign-in (one device, kept): a new login only when the stored one no longer works
tok=$(jq -r '.matrix.accessToken // empty' $CFG 2>/dev/null)
if [ -z "$tok" ] || [ "$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s' "$tok") $HS/_matrix/client/v3/account/whoami)" != 200 ]; then
  tok=$(jq -cn --arg p "$PW" '{type:"m.login.password",identifier:{type:"m.id.user",user:"fixer"},password:$p,initial_device_display_name:"Fixer (Pi)"}' \
    | curl -s -m 20 -H 'content-type: application/json' -d @- $HS/_matrix/client/v3/login | jq -r '.access_token // empty')
  [ -n "$tok" ] || { echo "the fixer's Matrix account does not log in"; exit 1; }
  rm -rf $H/.pi/matrix-bridge-crypto $H/.pi/matrix-bridge-store.json   # a new device starts with new keys
fi
# the settings: the bridge rewrites this file itself (trusted users), so only our keys are set, and the trusted
# list is put back to the owner alone on every run
T=$(mktemp)
{ cat $CFG 2>/dev/null || echo '{}'; } | jq --arg hs "$HS" --arg t "$tok" --arg o "matrix:@$OWNER:$NAME" \
  '.matrix = {homeserverUrl:$hs, accessToken:$t, encryption:false} | .auth.trustedUsers = [$o] | .auth.channels = {}
   | .hideThinking = true | .showWidget = false' > $T
changed=0; cmp -s $T $CFG || { install -o $U -g $U -m 600 $T $CFG; changed=1; }; rm -f $T

# the owner's chat with the fixer, already open in Element X
. /opt/lite-src/payload/matrix-dm.sh
FROOM=$(lite_dm $HS fixer "$PW" FIXER_ROOM "Fixer" "@$OWNER:$NAME") || echo "the chat with the fixer could not be made"
lite_owner_tidy $HS "$OWNER" "$(getv $MX OWNER_PASSWORD)" "$FROOM"

# 3. the service: Pi without a screen, as the bridge's own guide does it (script gives Pi a terminal)
UNIT=/etc/systemd/system/lite-fixer-chat.service
want=$(cat <<'UNITEOF'
[Unit]
Description=Fixer on Matrix (stock Pi with the pi-matrix-bridge package, Linux user fixer)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=fixer
WorkingDirectory=/home/fixer
Environment=HOME=/home/fixer
Environment=PATH=/home/fixer/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=PI_MATRIX_BRIDGE_AUTO_CONNECT=1
# Pi draws its screen into nothing; the bridge's one-time codes for strangers go nowhere either
StandardOutput=null
ExecStart=/usr/bin/script -qfec /home/fixer/.local/bin/pi /dev/null
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
)
if [ "$want" != "$(cat $UNIT 2>/dev/null)" ]; then printf '%s\n' "$want" > $UNIT; chmod 644 $UNIT; systemctl daemon-reload; changed=1; fi
systemctl enable -q lite-fixer-chat
if [ $changed = 1 ]; then systemctl restart lite-fixer-chat; else systemctl start lite-fixer-chat; fi
# up = the service stays running and the bridge has joined the owner's chat
ok=""
for _ in $(seq 1 20); do
  sleep 3
  m=$(curl -s -m 10 -H @<(printf 'Authorization: Bearer %s' "$tok") "$HS/_matrix/client/v3/joined_rooms" | jq -r --arg r "$FROOM" '.joined_rooms | index($r) // empty')
  systemctl is-active -q lite-fixer-chat && [ -n "$m" ] && { ok=1; break; }
done
echo "fixer: lite-fixer-chat $(systemctl is-active lite-fixer-chat); in the Fixer chat: $([ -n "$ok" ] && echo yes || echo no); answers only @$OWNER:$NAME"
[ -n "$ok" ] || { echo "the fixer is not on Matrix yet (journalctl -u lite-fixer-chat)"; exit 1; }
echo "STEP 76 OK"
