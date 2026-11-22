#!/bin/bash
# Step 50: connector programs for the driver, one per app. Root-owned and read-only to the agents.
#   /opt/lite/node        Node 24 LTS from nodejs.org (checksum-verified); several connectors need Node >= 24
#   /opt/lite/connectors  pinned third-party MCP servers from npm
# npm runs as "nobody" so package install scripts never run as root. Idempotent.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
NODE_V=v24.22.3
NODE_SHA=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb
PKGS="immich-mcp@0.5.2 actual-mcp@1.15.1 navidrome-mcp@3.1.0 dav-mcp@5.1.2 @bryanberger/jmap-mcp@0.3.0"
L=/opt/lite

if [ "$($L/node/bin/node --version 2>/dev/null)" != "$NODE_V" ]; then
  cd /tmp && curl -fsSL "https://nodejs.org/dist/$NODE_V/node-$NODE_V-linux-x64.tar.xz" -o node.tar.xz
  echo "$NODE_SHA  node.tar.xz" | sha256sum -c - >/dev/null
  rm -rf $L/node.new && mkdir -p $L/node.new && tar -xJf node.tar.xz -C $L/node.new --strip-components=1
  chown -R root:root $L/node.new && rm -rf $L/node && mv $L/node.new $L/node && rm -f node.tar.xz
fi

want=$(echo "$PKGS" | tr ' ' '\n' | sort | tr '\n' ' ')
have=$(cat $L/connectors/.pins 2>/dev/null || true)
if [ "$want" != "$have" ]; then
  S=$L/connectors.new
  rm -rf $S /tmp/lite-npm-home && install -d -o nobody -g nogroup $S /tmp/lite-npm-home
  ( cd $S && sudo -u nobody env HOME=/tmp/lite-npm-home PATH=$L/node/bin:/usr/bin:/bin \
      npm install --prefix $S --no-audit --no-fund --omit=dev --loglevel=error $PKGS ) >/var/log/lite-connectors-install.log 2>&1 \
    || { tail -25 /var/log/lite-connectors-install.log; echo "connector install failed"; exit 1; }
  echo "$want" > $S/.pins
  chown -R root:root $S && chmod -R go-w $S
  rm -rf $L/connectors.old; [ -d $L/connectors ] && mv $L/connectors $L/connectors.old
  mv $S $L/connectors && rm -rf $L/connectors.old /tmp/lite-npm-home
fi

echo "== result"
echo "node=$($L/node/bin/node --version)"
ls $L/connectors/node_modules/.bin | tr '\n' ' '; echo
( cd $L/connectors && $L/node/bin/npm ls --depth=0 2>/dev/null | sed -n 2,12p )
du -sh $L/connectors | cut -f1 | sed 's/^/size=/'
touch /etc/lite/versions; sed -i '/^connectors=/d' /etc/lite/versions; echo "connectors=$want" >> /etc/lite/versions
echo "STEP 50 OK"
