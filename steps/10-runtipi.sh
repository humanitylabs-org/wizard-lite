#!/bin/bash
# Step 10: stock Runtipi under the apps user's home, at a fixed version. No fork, no custom store.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
RUNTIPI_VERSION=${RUNTIPI_VERSION:-v4.12.0}
DIR=/home/apps/runtipi
install -d -o apps -g apps -m 755 "$DIR"
cd "$DIR"

if [ ! -x ./runtipi-cli ] || [ "$(./runtipi-cli version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//')" != "${RUNTIPI_VERSION#v}" ]; then
  ARCH=$(uname -m)
  curl -fsSL "https://github.com/runtipi/runtipi/releases/download/$RUNTIPI_VERSION/runtipi-cli-linux-$ARCH.tar.gz" -o cli.tgz
  NAME=$(tar -tzf cli.tgz | sed -n 1p | cut -f1 -d/)
  tar -xzf cli.tgz && mv -f "./$NAME" ./runtipi-cli && rm cli.tgz
  chmod +x ./runtipi-cli
fi
touch /etc/lite/versions
sed -i '/^runtipi=/d' /etc/lite/versions
echo "runtipi=$RUNTIPI_VERSION" >> /etc/lite/versions

install -d -o apps -g apps "$DIR/state"
if [ ! -f "$DIR/state/settings.json" ]; then
  echo '{"allowErrorMonitoring": false, "guestDashboard": false}' > "$DIR/state/settings.json"
  chown apps:apps "$DIR/state/settings.json"
fi

if docker ps --format '{{.Names}}' | grep -qx runtipi; then
  echo "runtipi already running"
else
  ./runtipi-cli start 2>&1 | tail -15
fi
# wait until the dashboard answers (a fresh start takes a minute or two)
for i in $(seq 1 60); do
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/api/user-context || true)
  [ "$c" = 200 ] && break
  sleep 5
done
[ "$c" = 200 ] || { echo "dashboard not answering after 5 minutes (last status $c)"; exit 1; }
echo "== result"
cat /etc/lite/versions
./runtipi-cli version 2>&1 | sed -n 1,3p
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "dashboard local: $(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/)"
echo "STEP 10 OK"
