#!/bin/bash
# Step 70: the three things only the owner can do, asked right here in the terminal the installer runs in:
#   1. sign this server in to their Tailscale     2. say which of their devices may open the apps
#   3. paste their Tinfoil key (it stays hidden)  then both AIs are checked and the app links are written.
# It then writes the private assistant's page of instructions and puts the three agent tiles on the dashboard.
# A thing that is already done is skipped, so running the installer again is how the owner changes the device
# list or the key. With no terminal attached (a test run over plain SSH) the questions are skipped.
set -uo pipefail
PROXY=http://127.0.0.1:3301/v1
MODEL=$(cat /etc/lite/default-model 2>/dev/null || echo glm-5-3)
DENV=/home/driver/.hermes/.env
DEVICES=/etc/lite/owner-devices
AGAIN="Run the installer again to finish this."
joined() { [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // ""')" = Running ]; }
name() { tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//'; }
# 200 = key works, 401/403 = Tinfoil refused it. The key goes to curl on stdin, never on a command line.
check_key() { printf 'Authorization: Bearer %s' "$1" | curl -s -m 40 -o /dev/null -w '%{http_code}' -H @- -H 'content-type: application/json' \
  -d "$(jq -nc --arg m "$MODEL" '{model:$m,max_tokens:1,messages:[{role:"user",content:"hi"}]}')" "$PROXY/chat/completions"; }

step_tailscale() {
  printf '\n1 of 3: your private network (Tailscale)\n'
  if joined; then echo "  Already joined as $(name)."; return 0; fi
  echo "  Open the link below on your phone or computer, sign in with your Tailscale account and choose Connect."
  echo "  This waits until the server has joined."
  tailscale up --hostname="$(hostname)" --ssh --force-reauth
  joined && echo "  Joined as $(name)." || { echo "  Not joined. $AGAIN"; return 1; }
}

step_devices() {
  # The apps open only from the devices picked here; the list goes to the firewall. Fail closed: no pick, no device.
  local peers n i pick line host os on ips
  printf '\n2 of 3: which of your devices may open the apps\n'
  joined || { echo "  The server is not on your Tailscale yet. $AGAIN"; return 1; }
  if [ -s "$DEVICES" ]; then
    echo "  Allowed now:"; sed 's/^.*# /    /' "$DEVICES"
    read -rp "  Change the list? [y/N] " pick; case "$pick" in y|Y) ;; *) return 0;; esac
  fi
  peers=$(tailscale status --json | jq -r '[.Peer[] | select(.HostName != null)] | sort_by(.HostName) | .[] | [.HostName, .OS, (if .Online then "online" else "offline" end), (.TailscaleIPs | join(" "))] | @tsv')
  [ -n "$peers" ] || { echo "  No other device is on your Tailscale yet. Install Tailscale on your phone or computer. $AGAIN"; return 1; }
  n=0; while IFS=$'\t' read -r host os on ips; do n=$((n+1)); printf '  %2d. %s (%s, %s)\n' "$n" "$host" "$os" "$on"; done <<< "$peers"
  read -rp "  Type the numbers of YOUR devices, separated by spaces (or all): " pick
  [ -n "$pick" ] || { echo "  Nothing picked; no device may open the apps yet. $AGAIN"; return 1; }
  [ "$pick" = all ] && pick=$(seq -s ' ' 1 "$n")
  : > "$DEVICES.new"
  for i in $pick; do
    line=$(sed -n "${i}p" <<< "$peers" 2>/dev/null) || true
    [ -n "$line" ] || { echo "  There is no device number '$i'. $AGAIN"; rm -f "$DEVICES.new"; return 1; }
    IFS=$'\t' read -r host os on ips <<< "$line"; echo "$ips # $host" >> "$DEVICES.new"
  done
  mv "$DEVICES.new" "$DEVICES"; chmod 640 "$DEVICES"
  bash /opt/lite-src/payload/firewall.sh >/dev/null && { echo "  Allowed:"; sed 's/^.*# /    /' "$DEVICES"; } || { echo "  The firewall refused the list. $AGAIN"; return 1; }
}

step_key() {
  local cur key code tmp
  printf '\n3 of 3: your private AI key (Tinfoil)\n'
  cur=$(grep -E '^HERMES_CUSTOM_TINFOIL_API_KEY=' "$DENV" 2>/dev/null | tail -1 | cut -d= -f2-)
  if [ -n "$cur" ] && [ "$(check_key "$cur")" = 200 ]; then echo "  Already connected."; return 0; fi
  echo "  Make a new API key just for this server at https://dash.tinfoil.sh and copy it."
  for _ in 1 2 3; do
    IFS= read -rsp "  Paste the key and press Enter (it stays hidden): " key || return 1; echo
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    [ -n "$key" ] || continue
    code=$(check_key "$key")
    case "$code" in
      200) tmp=$(mktemp); grep -v '^HERMES_CUSTOM_TINFOIL_API_KEY=' "$DENV" > "$tmp" 2>/dev/null || true
           printf 'HERMES_CUSTOM_TINFOIL_API_KEY=%s\n' "$key" >> "$tmp"
           install $( [ -f /home/driver/.hermes/.managed ] && echo "-o fixer -g driver -m 640" || echo "-o driver -g driver -m 600") "$tmp" "$DENV"; rm -f "$tmp"   # Hermes, user driver (owner: step 78)
           printf '%s\n' "$key" | install -m 600 -o fixer -g fixer /dev/stdin /home/fixer/.pi/agent/tinfoil.key   # Pi, user fixer
           echo "  Key works. Saved for Hermes and Pi."; return 0;;
      401|403) echo "  Tinfoil refused that key. Check you copied all of it.";;
      *) echo "  Could not reach Tinfoil (answer: $code). Try again in a minute.";;
    esac
  done
  echo "  No working key saved. $AGAIN"; return 1
}

step_check() {
  local a f
  printf '\nChecking that both AIs answer (about a minute)\n'
  a=$(timeout 150 sudo -iu driver hermes -z 'Reply with the single word READY.' 2>&1 | tail -c 300)
  printf '%s' "$a" | grep -qi READY && echo "  Hermes (user driver): ready." || echo "  Hermes (user driver): no answer. Last output: $(printf '%s' "$a" | tr '\n' ' ' | tail -c 160)"
  f=$(timeout 150 sudo -iu fixer pi --no-session -p 'Reply with the single word READY.' 2>&1 | tail -c 300)
  printf '%s' "$f" | grep -qi READY && echo "  Pi (user fixer): ready." || echo "  Pi (user fixer): no answer. Last output: $(printf '%s' "$f" | tr '\n' ' ' | tail -c 160)"
}

rc=0
if [ -t 0 ]; then
  step_tailscale && step_devices || rc=1
  step_key && step_check || rc=1
else
  echo "No terminal attached, so the three questions (Tailscale, devices, AI key) were not asked."
  echo "Run the installer in the server's own terminal to answer them."
fi

# https for the page, the apps and the tiles needs the server's Tailscale name, so it is (re)done here once the
# server has joined (step 65 installed Caddy; payload/https.sh skips everything until then).
if joined; then bash /opt/lite-src/payload/https.sh || rc=1; fi

# The app links, for the owner and for the private assistant's tour. Only root and the driver user can read them.
n=$(name); [ -n "$n" ] || n="(not on Tailscale yet)"
{ echo "Apps dashboard: https://$n/apps"; jq -r --arg n "$n" '.[] | "\(.what): https://\($n):\(.port)  (\(.name))"' /etc/lite/apps.json 2>/dev/null
  echo "Connected to the private assistant: $(tr '\n' ' ' < /etc/lite/connected-apps 2>/dev/null)"; } > /etc/lite/links.txt
chmod 640 /etc/lite/links.txt
install -D -m 640 -o root -g driver /etc/lite/links.txt /opt/lite/skills/lite-onboarding/references/links.md
chmod 750 /etc/lite

# The private assistant's own page (Hermes reads SOUL.md by itself): who it is, what it can and cannot do, and
# the apps with their links.
{ cat /opt/lite-src/payload/driver/SOUL.md; echo; sed 's/^/- /' /etc/lite/links.txt; } \
  | install $( [ -f /home/driver/.hermes/.managed ] && echo "-o fixer -g driver -m 640" || echo "-o driver -g driver -m 644") /dev/stdin /home/driver/.hermes/SOUL.md

# The three agent tiles on the apps dashboard. Each is a link to a browser terminal that already runs as that
# agent's Linux user (see payload/terminal.sh). Needs the server's Tailscale name, so only once it has joined.
tiles() {
  local u port title hint desc f tok new jar=/root/.lite-runtipi.cookies api=http://127.0.0.1/api links id body code up=0
  joined || { echo "Agent tiles: added once the server is on your Tailscale. $AGAIN"; return 1; }
  if [ "$(curl -s -m 15 -b "$jar" "$api/user-context" | jq -r .isLoggedIn 2>/dev/null)" != true ]; then
    . /etc/lite/runtipi-admin.env
    curl -s -m 30 -o /dev/null -c "$jar" -H 'content-type: application/json' \
      -d "$(jq -cn --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')" "$api/auth/login"
  fi
  links=$(curl -s -m 15 -b "$jar" "$api/links")
  while IFS='|' read -r u port title hint desc; do
    f=/etc/lite/terminal-$u.env
    tok=$(sed -n 's/^TOKEN=//p' "$f" 2>/dev/null)
    [ -n "$tok" ] || tok=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    new=$(printf 'PORT=%s\nTOKEN=%s\nTITLE="%s"\nHINT="%s"' "$port" "$tok" "$title" "$hint")
    systemctl enable -q "lite-terminal@$u"
    # A terminal that already runs with these settings on its socket is left alone: the owner may be running
    # this installer from inside it (the Fixer tile).
    if [ "$new" != "$(cat "$f" 2>/dev/null)" ] || ! systemctl is-active -q "lite-terminal@$u" \
       || ! ss -lxH 2>/dev/null | grep -q "/run/lite-terminal/$u/ttyd.sock "; then
      printf '%s\n' "$new" | install -m 600 /dev/stdin "$f"
      systemctl restart "lite-terminal@$u"
    fi
    # visible on Runtipi's guest dashboard (step 15), so the tile shows without a Runtipi login
    body=$(jq -nc --arg t "$title" --arg l "https://$n:$port/$tok/" --arg d "$desc" '{title:$t,url:$l,description:$d,isVisibleOnGuestDashboard:true}')
    id=$(printf '%s' "$links" | jq -r --arg t "$title" '.links[]? | select(.title==$t) | .id' | head -1)
    if [ -n "$id" ]; then code=$(curl -s -m 15 -b "$jar" -o /dev/null -w '%{http_code}' -X PATCH -H 'content-type: application/json' -H 'Origin: http://127.0.0.1' -d "$body" "$api/links/$id")
    else code=$(curl -s -m 15 -b "$jar" -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -H 'Origin: http://127.0.0.1' -d "$body" "$api/links"); fi
    case "$code" in 200|201) up=$((up+1));; *) echo "  The $title tile was refused by the dashboard (answer: $code).";; esac
  done <<'TILES'
driver|7681|Private assistant|This is your private assistant's terminal. Type: hermes|Hermes, for everyday things in your apps
fixer|7682|Fixer|This is the fixer's terminal, the only user with admin rights. Type: pi|Pi, for repairs on this server
frontier|7683|Frontier|This terminal is for frontier models, cut off from your apps. Type: claude or codex|Claude Code and Codex, cut off from your apps
TILES
  sleep 2
  echo "Agent tiles on the dashboard: $up of 3. Browser terminals running: $(systemctl is-active lite-terminal@driver lite-terminal@fixer lite-terminal@frontier | grep -cx active) of 3."
  [ "$up" = 3 ]
}
if [ -t 0 ] || joined; then tiles || rc=1; fi

[ $rc = 0 ] && echo "STEP 70 OK" || echo "STEP 70 INCOMPLETE"
exit $rc
