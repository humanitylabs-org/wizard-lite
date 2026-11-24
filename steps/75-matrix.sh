#!/bin/bash
# Step 75 (TEST, not decided; see PLAN.md): chat with the private assistant from a phone, over Matrix.
#   server     Conduit from the stock Runtipi store: one small program with its own database. Federation off,
#              registration off. Its name (the part after the colon in every Matrix address) is this server's
#              Tailscale name and can never change, so this step waits until the server has joined (step 70).
#   https      the same front door as the apps (payload/https.sh): https://NAME:6167, picked devices only.
#   accounts   made once while registration is briefly open behind a one-time token, then closed again:
#              the owner (login in /etc/lite/matrix-owner.txt, root only), the assistant, the fixer (step 76)
#              and approvals (step 77).
#   assistant  Hermes's own built-in Matrix connection for the driver user, as a background service
#              (lite-assistant-chat, like the terminal tiles). It answers only the owner and keeps the same trimmed tools
#              as in the terminal (step 60).
#   plain      no end-to-end encryption (Miguel's choice: Tailscale plus his own server is the boundary). Conduit is set
#              to refuse it, so rooms Element X makes are plain too, and nobody is asked for a recovery key.
# Idempotent; nothing secret is printed.
set -uo pipefail
E=/etc/lite; MX=$E/matrix.env; OWNTXT=$E/matrix-owner.txt; umask 077; touch $MX; chmod 600 $MX
APP=matrix-conduit; URN=$APP:migrated; C=${APP}_migrated-${APP}-1
UC=/home/apps/runtipi/user-config/migrated/$APP
JAR=/root/.lite-runtipi.cookies; RT=http://127.0.0.1/api
U=driver; HH=/home/$U/.hermes; DENV=$HH/.env
as() { sudo -iu $U bash -lc "$*"; }
getv() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
setv() { local f=$1 k=$2 v=$3 t; t=$(mktemp); grep -vE "^$k=" "$f" > "$t" || true; printf '%s=%s\n' "$k" "$v" >> "$t"; cat "$t" > "$f"; rm -f "$t"; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
rnd() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }

NAME=$(tailscale status --json 2>/dev/null | jq -r 'if .BackendState == "Running" then .Self.DNSName // "" else "" end' | sed 's/\.$//')
[ -n "$NAME" ] || { echo "matrix: added once the server is on your Tailscale (run the installer again then)"; echo "STEP 75 OK"; exit 0; }
OWNER=$(getv $E/owner.env OWNER_USER); OWNER=${OWNER:-owner}; BOT=assistant

rt_login() {
  [ "$(curl -s -m 15 -b $JAR $RT/user-context | jq -r .isLoggedIn)" = true ] && return 0
  . $E/runtipi-admin.env
  curl -s -m 30 -o /dev/null -c $JAR -H 'content-type: application/json' \
    -d "$(jq -cn --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')" $RT/auth/login
}
status_of() { curl -s -m 20 -b $JAR $RT/apps/installed | jq -r --arg u $URN '.installed[]? | select(.info.urn==$u) | .app.status' | sed -n 1p; }
port_of() { curl -s -m 20 -b $JAR $RT/apps/installed | jq -r --arg u $URN '.installed[]? | select(.info.urn==$u) | .app.port // .info.port' | sed -n 1p; }
hs_up() { [ "$(code "http://127.0.0.1:$PORT/_matrix/client/versions")" = 200 ]; }
restart_app() {  # through Runtipi, so its own records stay right; returns once Conduit answers again
  local before; before=$(docker inspect -f '{{.State.StartedAt}}' $C 2>/dev/null)
  rt_login
  [ "$(code -m 120 -b $JAR -H 'Origin: http://127.0.0.1' -X POST $RT/app-lifecycle/$URN/restart)" = 201 ] || { echo "Runtipi refused the restart"; return 1; }
  for _ in $(seq 1 45); do
    sleep 3; [ "$(docker inspect -f '{{.State.StartedAt}}' $C 2>/dev/null)" != "$before" ] && hs_up && return 0
  done; echo "Conduit did not come back after the restart"; return 1
}
# Conduit's own settings, through Runtipi's per-app override folder. The stock app is made for Runtipi's internet
# proxy only, so as shipped it has no port of its own, no field for its name, and does not start (Conduit wants
# CONDUIT_CONFIG set; empty means "settings from these variables"). Its port is opened on this server only
# (127.0.0.1); Caddy answers for it over Tailscale (step 3 below). The app's address it hands to phones
# (.well-known) must carry that port, or Element looks for it on the apps page's port 443.
# $1 = registration token, or empty for registration off.
override() {
  local want
  want=$(printf 'services:\n  %s:\n    ports:\n      - 127.0.0.1:%s:6167\n    environment:\n      - CONDUIT_CONFIG=\n      - CONDUIT_SERVER_NAME=%s\n      - CONDUIT_ENABLE_LIGHTNING_BOLT=false\n      - CONDUIT_ALLOW_ENCRYPTION=false\n      - CONDUIT_WELL_KNOWN_CLIENT=https://%s:%s\n' $APP "$PORT" "$NAME" "$NAME" "$PORT")
  if [ -n "$1" ]; then want=$(printf '%s\n      - CONDUIT_ALLOW_REGISTRATION=true\n      - CONDUIT_REGISTRATION_TOKEN=%s' "$want" "$1")
  else want=$(printf '%s\n      - CONDUIT_ALLOW_REGISTRATION=false' "$want"); fi
  [ "$(cat $UC/docker-compose.yml 2>/dev/null)" = "$want" ] && return 1
  install -d -m 755 /home/apps/runtipi/user-config/migrated $UC
  printf '%s\n' "$want" > $UC/docker-compose.yml; chown -R apps:apps $UC; chmod 600 $UC/docker-compose.yml
  return 0
}
# login check: true when USER's password works. The password goes to curl on stdin, and the check's session is
# signed out again at once, so checks do not pile up as devices on the account.
login_ok() {
  local t
  t=$(jq -cn --arg u "$1" --arg p "$2" '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p,initial_device_display_name:"installer check"}' \
    | curl -s -m 20 -H 'content-type: application/json' -d @- "http://127.0.0.1:$PORT/_matrix/client/v3/login" | jq -r '.access_token // empty')
  [ -n "$t" ] || return 1
  curl -s -m 20 -o /dev/null -X POST -H @<(printf 'Authorization: Bearer %s' "$t") "http://127.0.0.1:$PORT/_matrix/client/v3/logout"
}
# register USER PASSWORD TOKEN: the standard two-call registration with a registration token
register() {
  local s
  s=$(jq -cn --arg u "$1" --arg p "$2" '{username:$u,password:$p,inhibit_login:true}' \
      | curl -s -m 20 -H 'content-type: application/json' -d @- "http://127.0.0.1:$PORT/_matrix/client/v3/register" | jq -r '.session // empty')
  [ -n "$s" ] || return 1
  jq -cn --arg u "$1" --arg p "$2" --arg t "$3" --arg s "$s" '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}' \
    | curl -s -m 20 -H 'content-type: application/json' -d @- "http://127.0.0.1:$PORT/_matrix/client/v3/register" | jq -e '.user_id' >/dev/null
}

# 1. the homeserver, from the stock store, with its name set before its first start
rt_login
PORT=$(jq -r .port /home/apps/runtipi/repos/migrated/apps/$APP/config.json)
if [ -z "$(status_of)" ]; then
  override "" || true
  # The stock app insists on Runtipi's "expose to the internet" switch (force_expose) and a domain for it. It
  # gets a name that can never exist (.invalid is reserved), so Runtipi's own proxy never answers for it and its
  # certificate request fails at once; the app is reached only through its port, like the other apps.
  body='{"exposed":true,"domain":"matrix.invalid","exposedLocal":false,"openPort":true,"isVisibleOnGuestDashboard":true,"enableAuth":false}'
  c=$(curl -s -m 60 -o /tmp/rt-install.json -w '%{http_code}' -b $JAR -H 'content-type: application/json' -H 'Origin: http://127.0.0.1' -d "$body" $RT/app-lifecycle/$URN/install)
  case "$c" in 200|201) ;; *) echo "Conduit install refused ($c): $(cut -c1-300 /tmp/rt-install.json)"; exit 1;; esac
  for _ in $(seq 1 60); do case "$(status_of)" in running) break;; esac; sleep 5; done
fi
PORT=$(port_of); [ -n "$PORT" ] || { echo "Conduit is not installed"; exit 1; }
override "" && { restart_app || exit 1; }   # an app installed before these settings existed
for _ in $(seq 1 20); do hs_up && break; sleep 3; done
hs_up || { echo "Conduit does not answer on port $PORT"; docker logs --tail 20 $C 2>&1; exit 1; }
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $C | grep -qx "CONDUIT_SERVER_NAME=$NAME" || { echo "Conduit runs under another name than $NAME"; exit 1; }
echo "homeserver: $(docker inspect -f '{{.Config.Image}}' $C), name $NAME, port $PORT"

# 2. the accounts; registration is open only while one is missing, and only with a one-time token.
#    owner (first: Conduit makes the first account its admin), the assistant, the fixer (step 76) and approvals,
#    the account that asks the owner before any job goes to Frontier (step 77; not an agent, it only asks).
ACCTS="$OWNER:OWNER assistant:ASSISTANT fixer:FIXER approvals:APPROVALS"
for a in $ACCTS; do k=${a#*:}_PASSWORD; [ -n "$(getv $MX $k)" ] || setv $MX $k "$(rnd)"; done
missing() { local a; for a in $ACCTS; do login_ok "${a%%:*}" "$(getv $MX ${a#*:}_PASSWORD)" || { echo "${a%%:*}"; return 0; }; done; return 1; }
if missing >/dev/null; then
  tok=$(rnd); override "$tok" && { restart_app || exit 1; }
  for a in $ACCTS; do u=${a%%:*}; p=$(getv $MX ${a#*:}_PASSWORD)
    login_ok "$u" "$p" || register "$u" "$p" "$tok" || echo "could not create the account $u"
  done
fi
override "" && { restart_app || exit 1; }
m=$(missing) && { echo "the account $m does not log in"; exit 1; }
OPW=$(getv $MX OWNER_PASSWORD); BPW=$(getv $MX ASSISTANT_PASSWORD)
reg=$(curl -s -m 10 -H 'content-type: application/json' -d '{"username":"probe","password":"x"}' "http://127.0.0.1:$PORT/_matrix/client/v3/register" | jq -r '.errcode // "open"')
echo "accounts: $(for a in $ACCTS; do printf '@%s ' "${a%%:*}"; done)log in; registration: $reg"
[ "$reg" = M_FORBIDDEN ] || { echo "registration is not closed"; exit 1; }
# the owner's sign-in for Element X, root only; the installer shows it once at the end
printf 'Matrix: chat with your agents in the Element X app (two chats, no encryption, no recovery key)\nHomeserver: https://%s:%s\nUsername:   %s\nPassword:   %s\nAssistant:  @assistant:%s (everyday helper; builder jobs are approved here: react 👍 on the approval message)\nFixer:      @fixer:%s (repairs)\n' \
  "$NAME" "$PORT" "$OWNER" "$OPW" "$NAME" "$NAME" | install -m 600 /dev/stdin $OWNTXT

# 3. https on the same terms as the apps: listed in apps.json, so payload/https.sh gives it Caddy and the firewall
if ! jq -e --arg i $APP '.[] | select(.id==$i)' $E/apps.json >/dev/null; then
  jq --arg i $APP --argjson p "$PORT" '. + [{id:$i, name:"Conduit", port:$p, what:"chat (Matrix)"}]' $E/apps.json > $E/apps.json.new \
    && mv $E/apps.json.new $E/apps.json && chmod 640 $E/apps.json
fi
bash /opt/lite-src/payload/https.sh | tail -1
c=$(curl -s -m 15 -o /dev/null -w '%{http_code}' --resolve "$NAME:$((PORT + 10000)):127.0.0.1" "https://$NAME:$((PORT + 10000))/_matrix/client/versions")
echo "https: https://$NAME:$PORT answers $c"

# 4. the assistant: Hermes's Matrix packages. python-olm (encryption) is built from source; Hermes's own Python
#    asks for clang, so it is pointed at Debian's gcc, which is already here.
if ! /opt/lite/bin/hermes-driver pm status 2>/dev/null | jq -e '.feature_list | index("matrix")' >/dev/null; then
  CC=gcc CXX=g++ /opt/lite/bin/hermes-driver pm install --extra matrix 2>&1 | tail -2
fi
# the owner's chat with the assistant, already open in Element X; it is also the assistant's home chat, and
# @approvals sits in it to ask before any job goes to Frontier (step 77). Three members, so Hermes sees a group
# room: no @mention needed and no threads, as in a direct chat.
. /opt/lite-src/payload/matrix-dm.sh
AROOM=$(lite_dm http://127.0.0.1:$PORT $BOT "$BPW" ASSISTANT_ROOM "Assistant" "@$OWNER:$NAME" "@approvals:$NAME") || echo "the chat with the assistant could not be made"
lite_owner_tidy http://127.0.0.1:$PORT "$OWNER" "$OPW" "$AROOM"
# its settings, in its own secrets file, between markers so a rerun replaces them
new=$(printf '# lite matrix (start)\nMATRIX_HOMESERVER=http://127.0.0.1:%s\nMATRIX_USER_ID=@%s:%s\nMATRIX_PASSWORD=%s\nMATRIX_DEVICE_ID=HERMESLITE\nMATRIX_ALLOWED_USERS=@%s:%s\nMATRIX_E2EE_MODE=off\nMATRIX_REQUIRE_MENTION=false\nMATRIX_AUTO_THREAD=false\nMATRIX_HOME_ROOM=%s\n# lite matrix (end)' \
  "$PORT" $BOT "$NAME" "$BPW" "$OWNER" "$NAME" "$AROOM")
old=$(sed -n '/^# lite matrix (start)/,/^# lite matrix (end)/p' $DENV)
changed=0
if [ "$new" != "$old" ]; then
  T=$(mktemp); sed '/^# lite matrix (start)/,/^# lite matrix (end)/d' $DENV > $T; printf '%s\n' "$new" >> $T
  install $( [ -f /home/driver/.hermes/.managed ] && echo "-o fixer -g driver -m 640" || echo "-o driver -g driver -m 600") $T $DENV; rm -f $T; changed=1   # owner: step 78
fi
# the same trimmed tools in Matrix as in the terminal (step 60)
OFF="terminal file code_execution web browser computer_use image_gen tts vision delegation cronjob connections"
/opt/lite/bin/hermes-driver tools disable --platform matrix $OFF >/dev/null || { echo "tools could not be trimmed for Matrix"; exit 1; }
# no tool-progress lines ("⚙️ tool...") in the owner's chat; only the answers
if [ "$(/opt/lite/bin/hermes-driver config get display.platforms.matrix.tool_progress 2>/dev/null | tail -1)" != "false" ] && [ "$(/opt/lite/bin/hermes-driver config get display.platforms.matrix.tool_progress 2>/dev/null | tail -1)" != "off" ]; then
  /opt/lite/bin/hermes-driver config set display.platforms.matrix.tool_progress off >/dev/null && changed=1
fi
# Hermes's own Matrix connection runs as a background service of the driver user, like the terminal tiles:
# Hermes's stock "gateway run", kept up by systemd and restarted when these settings change.
UNIT=/etc/systemd/system/lite-assistant-chat.service
want=$(cat <<'UNITEOF'
[Unit]
Description=Private assistant on Matrix (stock Hermes gateway for the Linux user driver)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=driver
WorkingDirectory=/home/driver
Environment=HOME=/home/driver
ExecStart=/home/driver/.hermes/hermes-agent/.hermes/bin/hermes gateway run --replace --external-supervisor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF
)
if [ "$want" != "$(cat $UNIT 2>/dev/null)" ]; then printf '%s\n' "$want" > $UNIT; chmod 644 $UNIT; systemctl daemon-reload; changed=1; fi
systemctl enable -q lite-assistant-chat
if [ $changed = 1 ]; then systemctl restart lite-assistant-chat; else systemctl start lite-assistant-chat; fi
for _ in $(seq 1 30); do
  st=$(jq -r '.platforms.matrix.state // empty' $HH/gateway_state.json 2>/dev/null); [ "$st" = connected ] && break; sleep 3
done
echo "assistant: lite-assistant-chat $(systemctl is-active lite-assistant-chat); Matrix ${st:-not connected}"
echo "owner login: sudo cat $OWNTXT"
[ "$st" = connected ] || { echo "the assistant is not connected to Matrix yet (journalctl -u lite-assistant-chat)"; exit 1; }
echo "STEP 75 OK"
