#!/bin/bash
# Step 57: the mail app (Stalwart) for the owner, plus a key for the assistant's mail connector.
#   stalwart   first-run setup through the app's own API (no wizard clicks); the permanent admin login is kept
#              root-only in /etc/lite/owner.env as STALWART_ADMIN_USER / STALWART_ADMIN_PASSWORD
#   owner      the owner's mailbox OWNER_USER@OWNER_DOMAIN with the owner's password (web /account, IMAP, JMAP)
#   connector  an API key of the owner's mailbox only (not the owner's password) for the jmap-mcp connector,
#              stored in /etc/lite/connectors.env as JMAP_SESSION_URL / JMAP_BEARER_TOKEN
# Same rules as step 55: idempotent, nothing secret printed, ONLY="owner connector" runs some steps.
set -uo pipefail
E=/etc/lite; OWN=$E/owner.env; CONN=$E/connectors.env; umask 077; touch $OWN $CONN; chmod 600 $OWN $CONN
APP=stalwart-mail; C=${APP}_migrated-${APP}-1; B=http://127.0.0.1:8677
DATA=/home/apps/runtipi/app-data/migrated/$APP/data; UC=/home/apps/runtipi/user-config/migrated/$APP
JAR=/root/.lite-runtipi.cookies; RT=http://127.0.0.1/api

getv() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
setv() { local f=$1 k=$2 v=$3 t; t=$(mktemp); grep -vE "^$k=" "$f" > "$t" || true; printf '%s=%s\n' "$k" "$v" >> "$t"; cat "$t" > "$f"; rm -f "$t"; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
J() { jq -cn "$@"; }   # JSON bodies are built by jq so the shell never expands a secret
# logins travel to curl as a header read from a file descriptor (-H @<(...)), never on a command line
basic() { printf 'Authorization: Basic %s' "$(printf '%s:%s' "$1" "$2" | base64 -w0)"; }
bearer() { printf 'Authorization: Bearer %s' "$1"; }
admin() { basic "$(getv $OWN STALWART_ADMIN_USER)" "$(getv $OWN STALWART_ADMIN_PASSWORD)"; }
admin_ok() { [ "$(code -H @<(admin) $B/jmap/session)" = 200 ]; }
jmap() {  # one management call as the admin: jmap METHOD ARGS-JSON -> the method's response object
  curl -s -m 30 -H @<(admin) -H 'Content-Type: application/json' $B/jmap/ \
    -d "$(J --arg m "$1" --argjson a "$2" '{using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],methodCalls:[[$m,$a,"c"]]}')" | jq -c '.methodResponses[0][1]'; }
U=$(getv $OWN OWNER_USER); P=$(getv $OWN OWNER_PASSWORD); D=$(getv $OWN OWNER_DOMAIN); MAIL="$U@$D"
[ -n "$U" ] && [ -n "$P" ] && [ -n "$D" ] || { echo "run step 55 first (no owner login in $OWN)"; echo "STEP 57 INCOMPLETE"; exit 1; }

restart_app() {  # through Runtipi, so its own records stay right; returns once the new container answers
  local before; before=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)
  if [ "$(curl -s -m 15 -b $JAR $RT/user-context | jq -r .isLoggedIn)" != true ]; then
    . $E/runtipi-admin.env
    curl -s -m 30 -o /dev/null -c $JAR -H 'Content-Type: application/json' -d "$(J --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')" $RT/auth/login
  fi
  [ "$(code -m 120 -b $JAR -H 'Origin: http://127.0.0.1' -X POST $RT/app-lifecycle/$APP:migrated/restart)" = 201 ] || { echo "Runtipi refused the restart"; return 1; }
  for _ in $(seq 1 45); do
    sleep 4; [ "$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)" != "$before" ] && [ "$(code $B/healthz/live)" = 200 ] && sleep 3 && return 0
  done; echo "the app did not come back after the restart"; return 1
}

step_stalwart() {
  # The stock Runtipi compose keeps Stalwart's config file in a throw-away Docker volume that every restart
  # replaces, which would put the app back at its first-run screen each time. Runtipi's own per-app override
  # folder (user-config) moves that folder under the app's data directory, next to the mail database, and
  # tells the app its address: no public name points at this server, so the URL it publishes to JMAP clients
  # (the connector follows it) must be the one that works, http://127.0.0.1:8677. A phone's JMAP client would
  # need the Tailscale address there instead (one line below). IMAP/SMTP use a self-signed certificate.
  local want tmp changed=0 perms r
  install -d -m 755 /home/apps/runtipi/user-config/migrated "$UC"; install -d -m 750 -o 2000 -g 2000 "$DATA/data" "$DATA/etc"
  want=$(printf 'services:\n  %s:\n    volumes:\n      - ${APP_DATA_DIR}/data/etc:/etc/stalwart\n    environment:\n      - STALWART_PUBLIC_URL=%s\n' "$APP" "$B")
  [ "$(cat "$UC/docker-compose.yml" 2>/dev/null)" = "$want" ] || { printf '%s\n' "$want" > "$UC/docker-compose.yml"; changed=1; }
  chown -R apps:apps /home/apps/runtipi/user-config; chmod 644 "$UC/docker-compose.yml"
  if admin_ok; then
    [ $changed = 1 ] && { restart_app || return 1; }
    echo "already set up (hostname mail.$D, domain $D)"; return 0
  fi
  # first run: the app prints a one-time admin password in its log (a new one at every start)
  tmp=$(docker logs "$C" 2>&1 | grep -A3 'bootstrap mode - temporary' | awk '/password:/{p=$2} END{print p}')
  [ -n "$tmp" ] || { echo "the app is neither set up nor at first run (no first-run password in its log)"; return 1; }
  perms=$(curl -s -m 15 -H @<(basic admin "$tmp") $B/api/account | jq -r '.permissions[]?' | tr '\n' ' ')
  case "$perms" in *sysBootstrapUpdate*) ;; *) echo "the first-run password from the log is not accepted (restart the app and run again)"; return 1;; esac
  # the setup wizard's own form, filled in: one server, internal accounts, RocksDB under the app's data folder,
  # logs to the container output, no Let's Encrypt (no public name), no DNS provider, DKIM keys made anyway
  r=$(curl -s -m 90 -H @<(basic admin "$tmp") -H 'Content-Type: application/json' $B/jmap/ -d "$(J --arg h "mail.$D" --arg d "$D" \
    '{using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],methodCalls:[["x:Bootstrap/set",{update:{singleton:{serverHostname:$h,defaultDomain:$d,
      requestTlsCertificate:false,generateDkimKeys:true,dataStore:{"@type":"RocksDb",path:"/opt/stalwart-mail/data"},blobStore:{"@type":"Default"},
      searchStore:{"@type":"Default"},inMemoryStore:{"@type":"Default"},directory:{"@type":"Internal"},tracer:{"@type":"Stdout",ansi:false},dnsServer:{"@type":"Manual"}}}},"c"]]}')")
  [ -n "$(echo "$r" | jq -r '.methodResponses[0][1].updated.singleton.username // empty')" ] \
    || { echo "setup refused: $(echo "$r" | jq -c '.methodResponses[0][1].notUpdated // .' | cut -c1-200)"; return 1; }
  setv $OWN STALWART_ADMIN_USER "$(echo "$r" | jq -r '.methodResponses[0][1].updated.singleton.username')"
  setv $OWN STALWART_ADMIN_PASSWORD "$(echo "$r" | jq -r '.methodResponses[0][1].updated.singleton.secret')"
  # the config file the setup just wrote sits in the throw-away volume: keep a copy where the override mounts it
  docker exec "$C" cat /etc/stalwart/config.json > "$DATA/etc/config.json" && [ -s "$DATA/etc/config.json" ] || { echo "could not copy config.json out of the container"; return 1; }
  chown 2000:2000 "$DATA/etc/config.json"; chmod 644 "$DATA/etc/config.json"
  restart_app || return 1
  admin_ok && echo "set up: hostname mail.$D, domain $D, admin login kept in $OWN" || { echo "the permanent admin login does not work after the restart"; return 1; }
}

step_owner() {
  local dom id
  admin_ok || { echo "the app's admin login does not work"; return 1; }
  dom=$(jmap x:Domain/query "$(J --arg d "$D" '{filter:{name:$d}}')" | jq -r '.ids[0] // empty'); [ -n "$dom" ] || { echo "domain $D not found in the app"; return 1; }
  id=$(jmap x:Account/query "$(J --arg u "$U" '{filter:{name:$u}}')" | jq -r '.ids[0] // empty')
  if [ -z "$id" ]; then
    id=$(jmap x:Account/set "$(J --arg u "$U" --arg d "$dom" --arg p "$P" '{create:{u1:{"@type":"User",name:$u,domainId:$d,description:"Owner",roles:{"@type":"User"},credentials:{"0":{"@type":"Password",secret:$p}}}}}')" | jq -r '.created.u1.id // empty')
    [ -n "$id" ] || { echo "could not create the owner mailbox"; return 1; }
  elif [ "$(code -H @<(basic "$MAIL" "$P") $B/jmap/session)" != 200 ]; then   # mailbox exists, owner password changed since: follow it
    jmap x:Account/set "$(J --arg i "$id" --arg p "$P" '{update:{($i):{"credentials/0/secret":$p}}}')" | jq -e '.updated' >/dev/null || { echo "could not set the owner password"; return 1; }
  fi
  [ "$(code -H @<(basic "$MAIL" "$P") $B/jmap/session)" = 200 ] && echo "mailbox $MAIL ready (web /account, IMAP 993, SMTP 465, JMAP)" || { echo "owner login failed after setup"; return 1; }
}

step_connector() {
  # An API key is a bearer credential tied to one account: this one carries the owner's own permissions and
  # nothing more (admin calls are refused) and can be revoked without touching the owner's password.
  local id key r k
  key=$(getv $CONN JMAP_BEARER_TOKEN)
  if [ -n "$key" ] && [ "$(code -H @<(bearer "$key") $B/jmap/session)" = 200 ]; then echo "already connected"; return 0; fi
  admin_ok || { echo "the app's admin login does not work"; return 1; }
  id=$(jmap x:Account/query "$(J --arg u "$U" '{filter:{name:$u}}')" | jq -r '.ids[0] // empty'); [ -n "$id" ] || { echo "no owner mailbox yet"; return 1; }
  for k in $(jmap x:ApiKey/get "$(J --arg i "$id" '{accountId:$i,ids:null}')" | jq -r '.list[]? | select(.description=="assistant") | .id'); do   # leftovers of an earlier run
    jmap x:ApiKey/set "$(J --arg i "$id" --arg k "$k" '{accountId:$i,destroy:[$k]}')" >/dev/null
  done
  r=$(jmap x:ApiKey/set "$(J --arg i "$id" '{accountId:$i,create:{k1:{description:"assistant",permissions:{"@type":"Inherit"},allowedIps:{}}}}')")
  key=$(echo "$r" | jq -r '.created.k1.secret // empty'); [ -n "$key" ] || { echo "could not create an API key: $(echo "$r" | cut -c1-160)"; return 1; }
  setv $CONN JMAP_SESSION_URL $B/.well-known/jmap; setv $CONN JMAP_BEARER_TOKEN "$key"
  [ "$(code -H @<(bearer "$key") $B/jmap/session)" = 200 ] && echo "API key for the owner's mailbox created" || { echo "the new key is not accepted"; return 1; }
}

rc=0
for s in ${ONLY:-stalwart owner connector}; do
  printf '%-10s ' "$s"; out=$(step_$s 2>&1) && echo "OK   $out" || { echo "FAIL $out"; rc=1; }
done
echo "owner login: '$MAIL' with the owner password; admin and connector keys in $E (root-only)"
[ $rc = 0 ] && echo "STEP 57 OK" || echo "STEP 57 INCOMPLETE"
exit $rc
