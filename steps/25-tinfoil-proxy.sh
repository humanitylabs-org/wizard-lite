#!/bin/bash
# Step 25: Tinfoil's own proxy as a local service, at a fixed version. It checks the enclave's privacy proof
# (attestation) before any prompt leaves the box, and both agents talk to models only through it.
# Loopback only. It holds no key: each agent sends its own.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
TINFOIL_PROXY_VERSION=${TINFOIL_PROXY_VERSION:-0.2.9}

have=$(tinfoil-proxy --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ "$have" != "$TINFOIL_PROXY_VERSION" ]; then
  curl -fsSL https://github.com/tinfoilsh/tinfoil-proxy/raw/main/install.sh -o /tmp/tinfoil-proxy-install.sh
  VERSION=$TINFOIL_PROXY_VERSION sh /tmp/tinfoil-proxy-install.sh >/var/log/lite-tinfoil-proxy-install.log 2>&1 \
    || { tail -20 /var/log/lite-tinfoil-proxy-install.log; exit 1; }
fi
touch /etc/lite/versions; sed -i '/^tinfoil-proxy=/d' /etc/lite/versions; echo "tinfoil-proxy=$TINFOIL_PROXY_VERSION" >> /etc/lite/versions

cat > /etc/systemd/system/tinfoil-proxy.service <<'EOF'
[Unit]
Description=Tinfoil verified proxy (loopback 3301)
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
StateDirectory=tinfoil-proxy
Environment=HOME=/var/lib/tinfoil-proxy
ExecStart=/usr/local/bin/tinfoil-proxy --bind 127.0.0.1 --port 3301
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q tinfoil-proxy
systemctl restart tinfoil-proxy
sleep 8

echo "== result"
cat /etc/lite/versions
echo "service=$(systemctl is-active tinfoil-proxy)"
ss -tlnp | awk '/:3301 /{print "listening " $4}'
echo "verification document: $(curl -s -m 15 -o /tmp/tf-verify.json -w '%{http_code}' http://127.0.0.1:3301/verification-document)"
jq -c 'if type=="object" then (to_entries | map(select(.value|type!="object" and type!="array")) | from_entries) else . end' /tmp/tf-verify.json 2>/dev/null | cut -c1-600
journalctl -u tinfoil-proxy -n 8 --no-pager -o cat | cut -c1-200
echo "STEP 25 OK"
