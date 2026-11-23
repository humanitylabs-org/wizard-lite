#!/bin/bash
# Step 65: https. Installs stock Caddy from Debian's own archive (pinned to it, so no other source can replace
# it) and lets it fetch this server's Tailscale certificate. Then payload/https.sh writes Caddy's settings and
# the firewall's hand-over to it; until the server is on Tailscale (step 70 asks) that part waits, and step 70
# runs it again once the server has joined. Idempotent.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
cat > /etc/apt/preferences.d/lite-caddy <<'EOF'
# WizardOS lite: Caddy only from Debian's own archive
Package: caddy
Pin: release o=Debian
Pin-Priority: 1001

Package: caddy
Pin: release o=*
Pin-Priority: -1
EOF
if ! dpkg -s caddy 2>/dev/null | grep -q '^Status: install ok installed'; then
  # The package starts Caddy with its sample settings, which cannot get port 80 here (Runtipi has it).
  # That start failing is expected; Caddy is configured and started below.
  apt-get -o DPkg::Lock::Timeout=600 update -qq
  apt-get -o DPkg::Lock::Timeout=600 -y -qq install caddy >/dev/null 2>&1 || dpkg -s caddy | grep -q 'ok installed'
  # off until payload/https.sh has written its settings (at boot it would otherwise take port 80 from Runtipi)
  systemctl disable -q --now caddy 2>/dev/null || true
fi
echo "caddy=$(dpkg-query -W -f '${Version}' caddy) ($(apt-cache policy caddy | grep -A1 '^ \*\*\*' | tail -1 | awk '{print $2}'))"
bash /opt/lite-src/payload/https.sh
echo "STEP 65 OK"
