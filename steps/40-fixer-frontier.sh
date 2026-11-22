#!/bin/bash
# Step 40: the other two agents' tools, each under its own Linux user. Install only, no logins.
#   fixer   -> Pi (minimal harness, deliberately not Hermes), fixed version
#   frontier -> Claude Code and Codex CLIs (frontier models; no sudo, no docker, cannot read app data). These two
#               follow their makers' current release: their sign-in flows change often and a pinned old copy
#               stops signing in.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
PI_VERSION=${PI_VERSION:-0.73.1}
command -v npm >/dev/null || apt-get -o DPkg::Lock::Timeout=600 -y -qq install nodejs npm >/dev/null

as() { local u=$1; shift; sudo -iu "$u" bash -lc "$*"; }
for u in fixer frontier; do
  as $u 'mkdir -p ~/.local/bin && npm config set prefix ~/.local && grep -q "/.local/bin" ~/.profile 2>/dev/null || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.profile'
done

as fixer   "[ \"\$(pi --version 2>/dev/null)\" = $PI_VERSION ] || npm install -g --silent @mariozechner/pi-coding-agent@$PI_VERSION" >/var/log/lite-pi-install.log 2>&1 || { tail -15 /var/log/lite-pi-install.log; echo "pi install failed"; exit 1; }
as frontier 'command -v codex >/dev/null || npm install -g --silent @openai/codex' >/var/log/lite-codex-install.log 2>&1 || { tail -15 /var/log/lite-codex-install.log; echo "codex install failed"; }
as frontier 'command -v claude >/dev/null || npm install -g --silent @anthropic-ai/claude-code' >/var/log/lite-claude-install.log 2>&1 || { tail -15 /var/log/lite-claude-install.log; echo "claude install failed"; }
install -d -o frontier -g frontier -m 700 /home/frontier/code

echo "== result"
echo "node=$(node --version)"
PI=$(as fixer 'pi --version' 2>&1 | sed -n 1p);       echo "pi=$PI"
CX=$(as frontier 'codex --version' 2>&1 | sed -n 1p);  echo "codex=$CX"
CC=$(as frontier 'claude --version' 2>&1 | sed -n 1p); echo "claude=$CC"
[ "$PI" = "$PI_VERSION" ] || { echo "pi is $PI, wanted $PI_VERSION"; exit 1; }
touch /etc/lite/versions
sed -i '/^\(pi\|codex\|claude\)=/d' /etc/lite/versions
printf 'pi=%s\ncodex=%s\nclaude=%s\n' "$PI" "$CX" "$CC" >> /etc/lite/versions
echo "-- privilege check"
for u in driver frontier; do
  echo "$u sudo=$(sudo -n -l -U $u 2>&1 | grep -c 'may run' || true) docker=$(id -nG $u | grep -cw docker || true) reads-app-data=$(sudo -u $u test -r /home/apps/runtipi/app-data && echo YES || echo no)"
done
echo "fixer sudo=$(sudo -n -l -U fixer 2>&1 | grep -c 'may run' || true)"
echo "STEP 40 OK"
