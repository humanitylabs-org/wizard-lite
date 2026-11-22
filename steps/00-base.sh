#!/bin/bash
# Step 00: base system. Debian 13, patches, automatic security updates, key-only SSH, Docker, Tailscale
# (installed, not joined), the four Linux users. The server keeps the name and timezone chosen when Debian
# was installed. Idempotent: safe to re-run.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

echo "== packages"
apt-get -o DPkg::Lock::Timeout=600 update -qq
apt-get -o DPkg::Lock::Timeout=600 -y -qq -o Dpkg::Options::=--force-confold upgrade
apt-get -o DPkg::Lock::Timeout=600 -y -qq install ca-certificates curl gnupg git jq sudo nftables unattended-upgrades acl rsync

echo "== automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable -q --now unattended-upgrades

echo "== ssh: keys only"
cat > /etc/ssh/sshd_config.d/00-lite-keys-only.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t
systemctl reload ssh

echo "== docker (official repo)"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=600 update -qq
  apt-get -o DPkg::Lock::Timeout=600 -y -qq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable -q --now docker

echo "== tailscale (install only, not joined)"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi
systemctl enable -q --now tailscaled

echo "== users: apps, driver, fixer, frontier"
for u in apps driver fixer frontier; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
  chmod 700 "/home/$u"
  loginctl enable-linger "$u"
done
# Only the fixer has admin rights. The apps user runs Docker (Runtipi); driver and frontier get neither.
echo "fixer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/lite-fixer
chmod 440 /etc/sudoers.d/lite-fixer
visudo -cq
usermod -aG docker apps

echo "== result"
echo "os=$(. /etc/os-release; echo "$PRETTY_NAME")  host=$(hostname)  timezone=$(timedatectl show -p Timezone --value)"
echo "docker=$(docker --version)"
echo "compose=$(docker compose version --short)"
echo "tailscale=$(tailscale version | sed -n 1p)"
for u in apps driver fixer frontier; do echo "user $u groups=$(id -nG "$u" | tr ' ' ',') home=$(stat -c %a "/home/$u")"; done
echo "sudo: $(ls /etc/sudoers.d | tr '\n' ' ')"
sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "
echo "STEP 00 OK"
