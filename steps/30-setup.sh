#!/bin/bash
# Step 30: settings for the agents. Lays down the tour skill for the private assistant and Pi's one page of
# instructions, and points Hermes and Pi at the Tinfoil proxy. Installs no command of ours: the owner types
# hermes (as driver), pi (as fixer), claude or codex (as frontier). Asks nothing; step 70 asks for the key.
# Needs /opt/lite-src/payload. Idempotent.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
SRC=/opt/lite-src/payload
L=/opt/lite
U=driver
# One model per agent: the private assistant chats every day, so it gets the affordable GLM; the fixer is used
# sparingly and gets the strongest model, Kimi.
DRIVER_MODEL=${DRIVER_MODEL:-glm-5-3}
FIXER_MODEL=${FIXER_MODEL:-kimi-k3-1-pro}
as() { local u=$1; shift; sudo -iu "$u" bash -lc "$*"; }

echo "== tour skill, Pi instructions"
install -d -m 755 -o root -g root $L $L/skills; install -d -m 750 /etc/lite
rsync -a --delete --exclude='references/' --chown=root:root --chmod=D755,F644 "$SRC/skills/" $L/skills/
for c in lite-setup lite-health assistant fixer frontier builder; do rm -f /usr/local/bin/$c; done   # commands of earlier installs
echo "$DRIVER_MODEL" > /etc/lite/default-model   # the private assistant's model (step 70 and tests/ten.sh read it)
install -d -m 700 -o fixer -g fixer /home/fixer/.pi /home/fixer/.pi/agent
install -m 644 -o fixer -g fixer "$SRC/fixer/AGENTS.md" /home/fixer/.pi/agent/AGENTS.md

echo "== app list for the tour (from Runtipi)"
JAR=/root/.lite-runtipi.cookies
if [ "$(curl -s -m 15 -b "$JAR" http://127.0.0.1/api/user-context | jq -r .isLoggedIn)" != "true" ]; then
  . /etc/lite/runtipi-admin.env
  curl -s -m 30 -o /dev/null -c "$JAR" -H 'content-type: application/json' \
    -d "$(jq -cn --arg u "$RUNTIPI_ADMIN_USER" --arg p "$RUNTIPI_ADMIN_PASSWORD" '{username:$u,password:$p}')" http://127.0.0.1/api/auth/login
fi
curl -s -m 20 -b "$JAR" http://127.0.0.1/api/apps/installed | jq -c '
  {"immich":"photos","stalwart-mail":"mail","baikal":"calendar and contacts","filebrowser-quantum":"files","actual-budget":"budget","navidrome":"music","matrix-conduit":"chat (Matrix)"} as $w
  | [.installed[]? | {id:.info.id, name:.info.name, port:.info.port, what:($w[.info.id] // (.info.categories|join(", ")))}]' > /etc/lite/apps.json.new
[ "$(jq length /etc/lite/apps.json.new)" -gt 0 ] && mv /etc/lite/apps.json.new /etc/lite/apps.json
chmod 640 /etc/lite/apps.json
jq -r '.[] | "  \(.name): \(.what) (port \(.port))"' /etc/lite/apps.json

echo "== fixer: Pi points at the Tinfoil proxy (step 70 stores the key)"
jq -n --arg k '!cat /home/fixer/.pi/agent/tinfoil.key' '{providers:{tinfoil:{baseUrl:"http://127.0.0.1:3301/v1", api:"openai-completions",
        apiKey:$k, compat:{supportsDeveloperRole:false},
        models:[{id:"kimi-k3-1-pro"},{id:"glm-5-3"},{id:"deepseek-v4-1-flash"}]}}}' \
  | install -m 600 -o fixer -g fixer /dev/stdin /home/fixer/.pi/agent/models.json
# plain "pi" then starts on the private model (Pi's own default is Google); other settings the owner made are kept
S=/home/fixer/.pi/agent/settings.json
{ cat "$S" 2>/dev/null || echo '{}'; } | jq --arg m "$FIXER_MODEL" '. + {defaultProvider:"tinfoil", defaultModel:$m}' > "$S.new"
install -m 600 -o fixer -g fixer "$S.new" "$S"; rm -f "$S.new"

echo "== driver: Hermes points at the Tinfoil proxy (step 70 stores the key)"
cfg() { /opt/lite/bin/hermes-driver config set "$1" "$2" >/dev/null || { echo "config set $1 refused"; return 1; }; }
cfg providers.tinfoil.name Tinfoil
cfg providers.tinfoil.base_url http://127.0.0.1:3301/v1
cfg providers.tinfoil.key_env HERMES_CUSTOM_TINFOIL_API_KEY
cfg providers.tinfoil.api_mode chat_completions
cfg providers.tinfoil.discover_models false
cfg providers.tinfoil.model "$DRIVER_MODEL"
cfg model.provider tinfoil
cfg model.default "$DRIVER_MODEL"
cfg skills.external_dirs "[$L/skills]"

echo "== result"
echo "commands of ours in /usr/local/bin: $(ls /usr/local/bin | grep -cE '^(lite-|assistant$|fixer$|frontier$)' || true) (0 = none, as intended)"
echo "driver: $(as driver 'command -v hermes'), model $DRIVER_MODEL   fixer: $(as fixer 'command -v pi'), default $(jq -r '.defaultProvider + "/" + .defaultModel' $S)"
echo "driver sudo: $(sudo -u $U sudo -n true 2>&1 | grep -c 'password is required' || true) (1 = none, as intended)"
echo "frontier tools: $(as frontier 'command -v claude codex' | tr '\n' ' ')"
echo "STEP 30 OK"
