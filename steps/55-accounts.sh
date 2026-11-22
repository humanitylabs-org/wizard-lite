#!/bin/bash
# Step 55: the owner's account in each app, plus one credential per app for the assistant's connector.
#   /etc/lite/owner.env       the owner's login (root-only): one password for every app's own login screen
#   /etc/lite/connectors.env  what each connector needs (root-only); phase 60 hands these to the driver
# Each app is its own step: a step that is already done is skipped, a step that fails is reported and the
# others still run. Nothing secret is printed. Set ONLY="immich actual" to run some steps.
set -uo pipefail
L=/opt/lite; E=/etc/lite; APPDATA=/home/apps/runtipi/app-data/migrated
OWN=$E/owner.env; CONN=$E/connectors.env
install -d -m 755 $E; umask 077; touch $OWN $CONN; chmod 600 $OWN $CONN
export PATH=$L/node/bin:$PATH

getv() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
setv() { local f=$1 k=$2 v=$3 t; t=$(mktemp); grep -vE "^$k=" "$f" > "$t" || true; printf '%s=%s\n' "$k" "$v" >> "$t"; cat "$t" > "$f"; rm -f "$t"; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
rand() { head -c 64 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c "$1"; }
port() { jq -r --arg u "$1:migrated" '.installed[] | select(.info.urn==$u) | .app.port // .info.port' /root/.lite-apps.json 2>/dev/null; }
# the server's own timezone, as Baikal's list spells it (Debian says Etc/UTC, Baikal knows UTC)
TZ_NAME=${TZ_NAME:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}; case "$TZ_NAME" in Etc/*|"") TZ_NAME=UTC;; esac

[ -n "$(getv $OWN OWNER_PASSWORD)" ] || setv $OWN OWNER_PASSWORD "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"
[ -n "$(getv $OWN OWNER_USER)" ] || setv $OWN OWNER_USER owner
[ -n "$(getv $OWN OWNER_DOMAIN)" ] || setv $OWN OWNER_DOMAIN lite.internal
U=$(getv $OWN OWNER_USER); P=$(getv $OWN OWNER_PASSWORD); D=$(getv $OWN OWNER_DOMAIN); MAIL="$U@$D"
J() { jq -cn "$@"; }   # build JSON bodies without the shell touching the password

step_immich() {
  local B=http://127.0.0.1:8128/api key tok
  key=$(getv $CONN IMMICH_API_KEY)
  if [ -n "$key" ] && [ "$(code -H "x-api-key: $key" $B/users/me)" = 200 ]; then echo "already connected"; return 0; fi
  if [ "$(curl -s -m 15 $B/server/config | jq -r .isInitialized)" != true ]; then
    [ "$(code -X POST $B/auth/admin-sign-up -H 'Content-Type: application/json' -d "$(J --arg e "$MAIL" --arg p "$P" '{email:$e,password:$p,name:"Owner"}')")" = 201 ] || { echo "sign-up refused"; return 1; }
  fi
  tok=$(curl -s -m 15 -X POST $B/auth/login -H 'Content-Type: application/json' -d "$(J --arg e "$MAIL" --arg p "$P" '{email:$e,password:$p}')" | jq -r '.accessToken // empty')
  [ -n "$tok" ] || { echo "owner login failed"; return 1; }
  key=$(curl -s -m 15 -X POST $B/api-keys -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"name":"assistant","permissions":["all"]}' | jq -r '.secret // empty')
  [ -n "$key" ] || { echo "could not create an API key"; return 1; }
  setv $CONN IMMICH_BASE_URL $B; setv $CONN IMMICH_API_KEY "$key"
  [ "$(code -H "x-api-key: $key" $B/users/me)" = 200 ] && echo "owner account + API key created"
}

step_actual() {
  local B=http://127.0.0.1:8011 T id
  if [ "$(curl -s -m 15 $B/account/needs-bootstrap | jq -r .data.bootstrapped)" != true ]; then
    [ "$(curl -s -m 15 -X POST $B/account/bootstrap -H 'Content-Type: application/json' -d "$(J --arg p "$P" '{password:$p}')" | jq -r .status)" = ok ] || { echo "bootstrap refused"; return 1; }
  fi
  [ "$(curl -s -m 15 -X POST $B/account/login -H 'Content-Type: application/json' -d "$(J --arg p "$P" '{password:$p}')" | jq -r '.data.token // empty' | wc -c)" -gt 10 ] || { echo "owner login failed"; return 1; }
  id=$(getv $CONN ACTUAL_BUDGET_SYNC_ID)
  if [ -z "$id" ]; then
    T=$(mktemp -d); chown nobody:nogroup "$T"
    id=$(cd $L/connectors && sudo -u nobody env HOME="$T" ACTUAL_PW="$P" ACTUAL_URL=$B ACTUAL_DIR="$T" $L/node/bin/node --input-type=module -e '
      import { createRequire } from "node:module";
      const api = createRequire("/opt/lite/connectors/node_modules/actual-mcp/package.json")("@actual-app/api");
      await api.init({ dataDir: process.env.ACTUAL_DIR, serverURL: process.env.ACTUAL_URL, password: process.env.ACTUAL_PW });
      let b = (await api.getBudgets()).filter(x => x.groupId);
      if (!b.length) { await api.runImport("My Budget", async () => {}); await api.sync?.().catch(() => {}); b = (await api.getBudgets()).filter(x => x.groupId); }
      console.log("SYNCID=" + (b[0]?.groupId || ""));
      await api.shutdown();
    ' 2>/tmp/lite-actual.err | sed -n 's/^SYNCID=//p' | tail -1)
    rm -rf "$T"
    [ -n "$id" ] || { echo "could not create the first budget: $(tail -2 /tmp/lite-actual.err | cut -c1-200)"; return 1; }
  fi
  setv $CONN ACTUAL_SERVER_URL $B; setv $CONN ACTUAL_PASSWORD "$P"; setv $CONN ACTUAL_BUDGET_SYNC_ID "$id"
  echo "server password set, budget ready"
}

step_navidrome() {
  local B=http://127.0.0.1:4533 ok
  ok=$(curl -s -m 15 -X POST $B/auth/login -H 'Content-Type: application/json' -d "$(J --arg u "$U" --arg p "$P" '{username:$u,password:$p}')" | jq -r '.token // empty' | wc -c)
  if [ "$ok" -lt 10 ]; then
    ok=$(curl -s -m 15 -X POST $B/auth/createAdmin -H 'Content-Type: application/json' -d "$(J --arg u "$U" --arg p "$P" '{username:$u,password:$p}')" | jq -r '.token // empty' | wc -c)
    [ "$ok" -gt 10 ] || { echo "could not create the owner account"; return 1; }
  fi
  setv $CONN NAVIDROME_URL $B; setv $CONN NAVIDROME_USERNAME "$U"; setv $CONN NAVIDROME_PASSWORD "$P"
  echo "owner account ready"
}

step_baikal() {
  # Baikal has no API for setup: this walks its own install pages (settings, database), then adds the owner
  # as a calendar/contacts user through the admin pages. The admin password is the owner's password.
  local B=http://127.0.0.1:6556 JAR PF page T
  dav() { curl -s -m 15 -o /dev/null -w '%{http_code}' -u "$U:$P" -X PROPFIND -H 'Depth: 0' "$B/dav.php/calendars/$U/"; }
  if [ "$(dav)" = 207 ]; then
    setv $CONN CALDAV_SERVER_URL $B/dav.php; setv $CONN CALDAV_USERNAME "$U"; setv $CONN CALDAV_PASSWORD "$P"; echo "already set up"; return 0
  fi
  JAR=$(mktemp); PF=$(mktemp); printf %s "$P" > "$PF"
  tok() { grep -oE 'name="CSRF_TOKEN" value="[^"]+"' | head -1 | sed -E 's/.*value="([^"]+)"/\1/'; }
  page=$(curl -s -m 15 -b $JAR -c $JAR -L $B/admin/install/)
  if echo "$page" | grep -q 'Baikal_Model_Config_Standard::submitted'; then
    T=$(echo "$page" | tok)
    page=$(curl -s -m 20 -b $JAR -c $JAR -L $B/admin/install/ \
      -F 'Baikal_Model_Config_Standard::submitted=1' -F 'refreshed=0' -F "CSRF_TOKEN=$T" \
      -F "data[timezone]=$TZ_NAME" -F 'witness[timezone]=1' -F 'data[card_enabled]=1' -F 'witness[card_enabled]=1' \
      -F 'data[cal_enabled]=1' -F 'witness[cal_enabled]=1' -F 'data[invite_from]=' -F 'witness[invite_from]=1' \
      -F 'data[dav_auth_type]=Basic' -F 'witness[dav_auth_type]=1' \
      -F "data[admin_passwordhash]=<$PF" -F 'witness[admin_passwordhash]=1' -F "data[admin_passwordhash_confirm]=<$PF" -F 'witness[admin_passwordhash_confirm]=1')
  fi
  if echo "$page" | grep -q 'Baikal_Model_Config_Database::submitted'; then
    T=$(echo "$page" | tok)
    curl -s -m 20 -b $JAR -c $JAR -L -o /dev/null $B/admin/install/ \
      -F 'Baikal_Model_Config_Database::submitted=1' -F 'refreshed=0' -F "CSRF_TOKEN=$T" \
      -F 'data[backend]=sqlite' -F 'witness[backend]=1' -F 'data[sqlite_file]=/var/www/baikal/Specific/db/db.sqlite' -F 'witness[sqlite_file]=1'
  fi
  T=$(curl -s -m 15 -b $JAR -c $JAR -L $B/admin/ | tok)
  curl -s -m 15 -b $JAR -c $JAR -L -o /dev/null $B/admin/ -F 'auth=1' -F "CSRF_TOKEN=$T" -F 'login=admin' -F "password=<$PF"
  page=$(curl -s -m 15 -b $JAR -c $JAR -L "$B/admin/?/users/new/1/")
  if echo "$page" | grep -q 'Baikal_Model_User::submitted'; then
    T=$(echo "$page" | tok)
    curl -s -m 20 -b $JAR -c $JAR -L -o /dev/null "$B/admin/?/users/new/1/" \
      -F 'Baikal_Model_User::submitted=1' -F 'refreshed=0' -F "CSRF_TOKEN=$T" \
      -F "data[username]=$U" -F 'witness[username]=1' -F 'data[displayname]=Owner' -F 'witness[displayname]=1' \
      -F "data[email]=$MAIL" -F 'witness[email]=1' -F "data[password]=<$PF" -F 'witness[password]=1' -F "data[passwordconfirm]=<$PF" -F 'witness[passwordconfirm]=1'
  fi
  rm -f $JAR $PF
  [ "$(dav)" = 207 ] || { echo "the owner's calendar did not answer (status $(dav))"; return 1; }
  setv $CONN CALDAV_SERVER_URL $B/dav.php; setv $CONN CALDAV_USERNAME "$U"; setv $CONN CALDAV_PASSWORD "$P"
  echo "installed, owner calendar and address book created"
}

step_files() {
  # FileBrowser Quantum: no connector exists for it (open question in PLAN.md), but the owner still gets an
  # account. The app prints a random password for its built-in "admin" at first start and insists on a change
  # at the first login (POST /api/auth/password/change-required, the app's own flow); the owner's password
  # becomes the admin password, so the one in the container log stops working. Then the owner's own account
  # is created. Login: POST /api/auth/login?username=... with the password in the X-Password header. Keep the
  # tries few: the app locks the address out for a while after a handful of failed logins.
  local B=http://127.0.0.1:18196 C=filebrowser-quantum_migrated-filebrowser-quantum-1 TK gen c body
  login() { TK=$(curl -s -m 15 -o /dev/stdout -w '\n%{http_code}' -X POST -H "X-Password: $2" "$B/api/auth/login?username=$1"); c=${TK##*$'\n'}; TK=${TK%$'\n'*}; [ "$c" = 200 ]; }
  auth() { printf 'Authorization: Bearer %s' "$TK"; }   # the token goes to curl on stdin (-H @-), never on a command line
  login "$U" "$P" && { echo "already set up"; return 0; }
  [ "$c" = 429 ] && { echo "the app is refusing logins for a while (too many tries); run again later"; return 1; }
  if ! login admin "$P"; then
    gen=$(docker logs "$C" 2>&1 | grep -m1 'Generated initial admin password' | sed -E 's/.*: //')
    [ -n "$gen" ] || { echo "no first-start password in the app log and the owner's does not work"; return 1; }
    TK=$(curl -s -m 15 -o /dev/stdout -w '\n%{http_code}' -X POST -H "X-Password: $gen" -H 'Content-Type: application/json' \
      -d "$(J --arg p "$P" '{password:$p,passwordConfirm:$p}')" "$B/api/auth/password/change-required?username=admin")
    c=${TK##*$'\n'}; TK=${TK%$'\n'*}
    [ "$c" = 200 ] || { echo "first-login password change refused (status $c)"; return 1; }
  fi
  body=$(J --arg u "$U" --arg p "$P" '{which:[],data:{username:$u,password:$p,loginMethod:"password",
        permissions:{admin:true,api:false,share:true,realtime:true},scopes:[{name:"files",scope:"/",permissions:{view:true,download:true,modify:true,create:true,delete:true}}]}}')
  # creating a user asks the admin to confirm its own password (X-Password); the admin's is the owner's by now
  c=$(auth | code -H @- -H "X-Password: $P" -H 'Content-Type: application/json' -X POST -d "$body" "$B/api/users")
  case "$c" in 200|201|409) ;; *) echo "could not create the owner account (status $c)"; return 1;; esac
  login "$U" "$P" && echo "owner account ready" || { echo "owner login failed after setup (status $c)"; return 1; }
}

rc=0
LIST="actual navidrome baikal files"; [ -n "$(port immich)" ] && LIST="immich $LIST"   # photos only when installed
for s in ${ONLY:-$LIST}; do
  printf '%-10s ' "$s"; out=$(step_$s 2>&1) && echo "OK   $out" || { echo "FAIL $out"; rc=1; }
done
echo "owner login: user '$U', mail-style login '$MAIL', password in $OWN"
echo "connector keys held: $(cut -d= -f1 $CONN | tr '\n' ' ')"
[ $rc = 0 ] && echo "STEP 55 OK" || echo "STEP 55 INCOMPLETE"
exit $rc
