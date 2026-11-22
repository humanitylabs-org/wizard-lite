#!/bin/bash
# Step 15: starter apps from the STOCK Runtipi store, latest version of each (no pins, no custom store).
# Photos (Immich) is not in the first install: it is most of the download and the one app that fails on a
# slow start. APPS="... immich" adds it; the waits and the database repair below are for that case.
# Installs one at a time through Runtipi's own API and waits until each reports running. Idempotent.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
JAR=/root/.lite-runtipi.cookies
API=http://127.0.0.1/api
APPS=${APPS:-"baikal actual-budget navidrome filebrowser-quantum stalwart-mail"}
BODY='{"exposed":false,"exposedLocal":false,"openPort":true,"isVisibleOnGuestDashboard":false,"enableAuth":false}'

status_of() { curl -s -m 20 -b "$JAR" "$API/apps/installed" | jq -r --arg u "$1" '.installed[]? | select(.info.urn==$u) | .app.status' | sed -n 1p; }

# refresh the session if the cookie expired
if [ "$(curl -s -m 15 -b "$JAR" "$API/user-context" | jq -r .isLoggedIn)" != "true" ]; then
  . /etc/lite/runtipi-admin.env
  curl -s -m 30 -o /dev/null -c "$JAR" -H 'content-type: application/json' \
    -d "$(jq -cn --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')" "$API/auth/login"
fi

# Stock-store Immich bug seen on first install (Runtipi v4.12.0, Immich v3.4.2): the database container's
# first start fails on folder permissions, restarts, and then skips creating the "immich" database, so the
# server crash-loops until it exists. Called while waiting for Immich; creates the database once it is missing.
fix_immich_db() {
  local DBC=immich_migrated-immich-db-1
  docker ps --format '{{.Names}}' | grep -qx "$DBC" || return 0
  docker exec "$DBC" psql -U tipi -d postgres -Atc "select 1 from pg_database where datname='immich'" 2>/dev/null | grep -q 1 && return 0
  docker exec "$DBC" createdb -U tipi immich 2>/dev/null && echo "immich: created missing database"
  return 0
}

for id in $APPS; do
  urn="$id:migrated"
  st=$(status_of "$urn")
  if [ -z "$st" ]; then
    code=$(curl -s -m 60 -o /tmp/rt-install.json -w '%{http_code}' -b "$JAR" -H 'content-type: application/json' -H 'Origin: http://127.0.0.1' -d "$BODY" "$API/app-lifecycle/$urn/install")
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
      echo "$id: install request refused ($code): $(cut -c1-300 /tmp/rt-install.json)"; continue
    fi
  fi
  for i in $(seq 1 90); do
    st=$(status_of "$urn")
    case "$st" in running|stopped) break;; esac
    [ "$id" = immich ] && fix_immich_db
    sleep 10
  done
  # Runtipi gives an install five minutes; on a slow line or machine a big image (Immich) takes longer and the
  # app is parked as "stopped". Starting it pulls the rest and brings it up.
  if [ "$st" = stopped ]; then
    curl -s -m 60 -o /dev/null -b "$JAR" -H 'content-type: application/json' -H 'Origin: http://127.0.0.1' -X POST "$API/app-lifecycle/$urn/start"
    for i in $(seq 1 120); do
      st=$(status_of "$urn")
      case "$st" in running) break;; esac
      [ "$id" = immich ] && fix_immich_db
      sleep 10
    done
  fi
  # "running" in Runtipi only means the containers exist. On a fast machine that comes before the database
  # container has settled, so keep repairing until Immich itself answers (up to ten minutes).
  if [ "$id" = immich ] && [ "$st" = running ]; then
    for i in $(seq 1 60); do
      fix_immich_db
      curl -s -m 10 http://127.0.0.1:8128/api/server/ping 2>/dev/null | grep -q pong && break
      sleep 10
    done
    curl -s -m 10 http://127.0.0.1:8128/api/server/ping 2>/dev/null | grep -q pong || st="not answering"
  fi
  echo "$id: ${st:-not listed}"
  [ "$st" = running ] || failed="$failed $id"
done

[ -z "${failed:-}" ] || { echo "not running:$failed"; exit 1; }

echo "== result"
curl -s -m 20 -b "$JAR" "$API/apps/installed" > /root/.lite-apps.json
jq -r '.installed[]? | "\(.info.id)\t\(.app.status)\tv\(.info.version)\tport \(.info.port)"' /root/.lite-apps.json
touch /etc/lite/versions; sed -i '/^apps=/d' /etc/lite/versions
echo "apps=$(jq -r '[.installed[]? | "\(.info.id)@\(.info.version)"] | join(" ")' /root/.lite-apps.json)" >> /etc/lite/versions
free -m | awk 'NR==2{print "memory used " $3 " MB of " $2 " MB"}'
df -h / | awk 'NR==2{print "disk used " $3 " of " $2}'
echo "STEP 15 OK"
