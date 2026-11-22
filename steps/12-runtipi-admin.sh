#!/bin/bash
# Step 12: Runtipi admin account for the box itself (random password, root-only file), then a session
# cookie the later phases reuse. Idempotent. Never prints the password.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
ENVF=/etc/lite/runtipi-admin.env
JAR=/root/.lite-runtipi.cookies
API=http://127.0.0.1/api

if [ ! -f "$ENVF" ]; then
  umask 077
  printf 'RUNTIPI_ADMIN_USER=%s\nRUNTIPI_ADMIN_PASSWORD=%s\n' "admin@lite.internal" "$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)" > "$ENVF"
fi
chmod 600 "$ENVF"
. "$ENVF"
BODY=$(jq -cn --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')

configured=$(curl -s -m 15 "$API/user-context" | jq -r '.isConfigured // empty')
echo "configured_before=$configured"
if [ "$configured" != "true" ]; then
  code=$(curl -s -m 30 -o /tmp/rt-register.json -w '%{http_code}' -c "$JAR" -H 'content-type: application/json' -d "$BODY" "$API/auth/register")
  echo "register=$code"
fi
code=$(curl -s -m 30 -o /tmp/rt-login.json -w '%{http_code}' -c "$JAR" -H 'content-type: application/json' -d "$BODY" "$API/auth/login")
echo "login=$code"
chmod 600 "$JAR"
curl -s -m 15 -b "$JAR" "$API/user-context" | jq -c '{isLoggedIn, isConfigured, version: .version.current}'
echo "== stores"
curl -s -m 15 -b "$JAR" "$API/marketplace/all" | jq -c '.appStores[]? | {slug, name, url, enabled}' 2>/dev/null || curl -s -m 15 -b "$JAR" "$API/marketplace/all" | cut -c1-400
echo "STEP 12 OK"
