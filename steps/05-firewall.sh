#!/bin/bash
# Step 05: firewall. Writes the three rules (see payload/firewall.sh) and the boot-time service that loads
# them, then applies them. Which devices may open the apps is asked at the end of the install (step 70);
# until then no Tailscale device reaches the apps. Idempotent.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
SRC=/opt/lite-src/payload
install -d -m 750 /etc/lite
rm -f /usr/local/sbin/lite-firewall   # a command of earlier installs

cat > /etc/systemd/system/lite-firewall.service <<'EOF'
[Unit]
Description=Lite firewall (internet closed, owner's Tailscale devices only, frontier walled off)
Before=docker.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/lite/firewall.nft
ExecStop=/usr/sbin/nft delete table inet lite_fw

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q lite-firewall
# SSH on the public interface stays allowed, so the installer cannot lock itself out; a provider console
# always works regardless.
bash "$SRC/firewall.sh"
nft list table inet lite_fw | grep -cE "accept|drop|reject"
echo "STEP 05 OK"
