#!/bin/bash
# Step 40: the other two agents' tools, each under its own Linux user. Install only, no logins.
#   fixer   -> Pi (minimal harness, deliberately not Hermes), fixed version
#   frontier -> Claude Code and Codex CLIs (frontier models; no sudo, no docker, cannot read app data). These two
#               follow their makers' current release: their sign-in flows change often and a pinned old copy
#               stops signing in. Each gets one short page of instructions, and Claude Code's connectors to
#               the owner's Claude account (mail, calendar, drive) are switched off: frontier touches no app.
# Also the browser terminal (stock ttyd, fixed version) behind the three tiles on the apps dashboard, one
# service per Linux user. Step 70 switches them on once the server has its Tailscale address.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
PI_VERSION=${PI_VERSION:-0.73.1}
SRC=/opt/lite-src/payload
TTYD_VERSION=1.7.7
case $(uname -m) in
  x86_64)  TTYD_FILE=ttyd.x86_64;  TTYD_SHA=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55;;
  aarch64) TTYD_FILE=ttyd.aarch64; TTYD_SHA=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165;;
  *) echo "no browser terminal for $(uname -m)"; exit 1;;
esac
command -v npm >/dev/null || apt-get -o DPkg::Lock::Timeout=600 -y -qq install nodejs npm >/dev/null

as() { local u=$1; shift; sudo -iu "$u" bash -lc "$*"; }
for u in fixer frontier; do
  as $u 'mkdir -p ~/.local/bin && npm config set prefix ~/.local && grep -q "/.local/bin" ~/.profile 2>/dev/null || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.profile'
done

as fixer   "[ \"\$(pi --version 2>/dev/null)\" = $PI_VERSION ] || npm install -g --silent @mariozechner/pi-coding-agent@$PI_VERSION" >/var/log/lite-pi-install.log 2>&1 || { tail -15 /var/log/lite-pi-install.log; echo "pi install failed"; exit 1; }
as frontier 'command -v codex >/dev/null || npm install -g --silent @openai/codex' >/var/log/lite-codex-install.log 2>&1 || { tail -15 /var/log/lite-codex-install.log; echo "codex install failed"; }
as frontier 'command -v claude >/dev/null || npm install -g --silent @anthropic-ai/claude-code' >/var/log/lite-claude-install.log 2>&1 || { tail -15 /var/log/lite-claude-install.log; echo "claude install failed"; }
install -d -o frontier -g frontier -m 700 /home/frontier/code

# frontier: the same page for both tools, in the file each one reads by itself
install -d -o frontier -g frontier -m 700 /home/frontier/.claude /home/frontier/.codex
install -m 644 -o frontier -g frontier "$SRC/frontier/INSTRUCTIONS.md" /home/frontier/.claude/CLAUDE.md
install -m 644 -o frontier -g frontier "$SRC/frontier/INSTRUCTIONS.md" /home/frontier/.codex/AGENTS.md
# Claude Code's own machine-wide settings file (root-owned, so the agent cannot switch it back)
install -d -m 755 /etc/claude-code
echo '{"disableClaudeAiConnectors": true, "env": {"ENABLE_CLAUDEAI_MCP_SERVERS": "false"}}' > /etc/claude-code/managed-settings.json
chmod 644 /etc/claude-code/managed-settings.json

# browser terminal: stock ttyd at a fixed version, checked against its published checksum
install -d -m 755 /opt/lite/bin
if [ "$(sha256sum /opt/lite/bin/ttyd 2>/dev/null | cut -d' ' -f1)" != "$TTYD_SHA" ]; then
  curl -fsSL -o /tmp/ttyd "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/$TTYD_FILE"
  echo "$TTYD_SHA  /tmp/ttyd" | sha256sum -c --quiet
  install -m 755 -o root -g root /tmp/ttyd /opt/lite/bin/ttyd; rm -f /tmp/ttyd
fi
cat > /etc/systemd/system/lite-terminal@.service <<'UNIT'
[Unit]
Description=Browser terminal for the Linux user %i (a tile on the apps dashboard; owner's Tailscale devices only)
After=tailscaled.service lite-firewall.service

[Service]
User=%i
EnvironmentFile=/etc/lite/terminal-%i.env
# never starts without the firewall's rules loaded (checked as root); a later firewall reload leaves it running,
# so the installer can be run again from the Fixer tile
ExecStartPre=+/usr/sbin/nft list table inet lite_fw
# its socket's folder: this user and the caddy group only (Caddy is installed in step 65)
ExecStartPre=+/usr/bin/install -d -m 2750 -o %i -g caddy /run/lite-terminal/%i
ExecStart=/bin/bash /opt/lite-src/payload/terminal.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

echo "== result"
echo "node=$(node --version)"
PI=$(as fixer 'pi --version' 2>&1 | sed -n 1p);       echo "pi=$PI"
CX=$(as frontier 'codex --version' 2>&1 | sed -n 1p);  echo "codex=$CX"
CC=$(as frontier 'claude --version' 2>&1 | sed -n 1p); echo "claude=$CC"
[ "$PI" = "$PI_VERSION" ] || { echo "pi is $PI, wanted $PI_VERSION"; exit 1; }
touch /etc/lite/versions
sed -i '/^\(pi\|codex\|claude\)=/d' /etc/lite/versions
printf 'pi=%s\ncodex=%s\nclaude=%s\n' "$PI" "$CX" "$CC" >> /etc/lite/versions
TT=$(/opt/lite/bin/ttyd --version | awk '{print $3}')
sed -i '/^ttyd=/d' /etc/lite/versions; echo "ttyd=$TT" >> /etc/lite/versions
echo "ttyd=$TT  frontier pages: $(ls /home/frontier/.claude/CLAUDE.md /home/frontier/.codex/AGENTS.md | wc -l)  claude account connectors off: $(jq -r .disableClaudeAiConnectors /etc/claude-code/managed-settings.json)"
echo "-- privilege check"
for u in driver frontier; do
  echo "$u sudo=$(sudo -n -l -U $u 2>&1 | grep -c 'may run' || true) docker=$(id -nG $u | grep -cw docker || true) reads-app-data=$(sudo -u $u test -r /home/apps/runtipi/app-data && echo YES || echo no)"
done
echo "fixer sudo=$(sudo -n -l -U fixer 2>&1 | grep -c 'may run' || true)"
echo "STEP 40 OK"
