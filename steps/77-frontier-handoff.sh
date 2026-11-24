#!/bin/bash
# Step 77 (TEST, see PLAN.md): the private assistant may pass a job to Frontier, and only with the owner's yes,
# asked in Matrix every single time.
#   Why not Hermes's own approvals: on Matrix they always offer "this session" and "always" as well as "once", no
#   setting removes those two, and the assistant's own settings are where such an answer would be stored.
#   So the yes is asked outside the assistant (custom, as small as possible, two files in payload/handoff):
#   gate      /opt/lite/bin/lite-handoff (root). The driver user may run it through sudo, with no arguments, and
#             nothing else. It shows the owner the brief exactly as it will run, from its own account @approvals
#             right in the Assistant chat (as a notice, which the assistant ignores), waits for the owner's thumbs up
#             reaction on that one message (anything else, typing included, or 10 minutes of silence is no), then runs Claude Code (or Codex) as the frontier user in a new
#             folder under /srv/lite-frontier (frontier writes it, driver can read it) and hands back the answer.
#   tool      /opt/lite/bin/lite-handoff-mcp: one MCP tool, give_to_frontier, for the assistant; it only forwards.
# Frontier keeps its firewall wall: it reaches nothing on this server. Idempotent; nothing secret is printed.
set -uo pipefail
E=/etc/lite; MX=$E/matrix.env; HE=$E/handoff.env; SRC=/opt/lite-src/payload/handoff
U=driver; HH=/home/$U/.hermes
getv() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
setv() { local f=$1 k=$2 v=$3 t; t=$(mktemp); grep -vE "^$k=" "$f" > "$t" || true; printf '%s=%s\n' "$k" "$v" >> "$t"; cat "$t" > "$f"; rm -f "$t"; }
hd() { /opt/lite/bin/hermes-driver "$@"; }   # step 78: the fixer owns the assistant's settings
NAME=$(tailscale status --json 2>/dev/null | jq -r 'if .BackendState == "Running" then .Self.DNSName // "" else "" end' | sed 's/\.$//')
[ -n "$NAME" ] && [ -n "$(getv $MX APPROVALS_PASSWORD)" ] || { echo "frontier handoff: added once Matrix is set up (step 75)"; echo "STEP 77 OK"; exit 0; }
OWNER=$(getv $E/owner.env OWNER_USER); OWNER=${OWNER:-owner}
PORT=$(jq -r '.[] | select(.id=="matrix-conduit") | .port' $E/apps.json)

# 1. the two files (plain Python, root runs nothing from the agents' folders), root-owned; the jobs folder; the one sudo rule
install -d -m 755 /opt/lite/bin
install -m 755 -o root -g root $SRC/lite-handoff /opt/lite/bin/lite-handoff
tool_before=$(md5sum < /opt/lite/bin/lite-handoff-mcp 2>/dev/null)
install -m 755 -o root -g root $SRC/handoff-mcp /opt/lite/bin/lite-handoff-mcp
install -d -m 2750 -o frontier -g driver /srv/lite-frontier
printf '# Step 77: the private assistant may ask the owner to approve one Frontier job, and nothing else as root or frontier\n%s ALL=(root) NOPASSWD: /opt/lite/bin/lite-handoff ""\n' $U \
  | install -m 440 /dev/stdin /etc/sudoers.d/lite-handoff.new
visudo -cqf /etc/sudoers.d/lite-handoff.new && mv /etc/sudoers.d/lite-handoff.new /etc/sudoers.d/lite-handoff \
  || { rm -f /etc/sudoers.d/lite-handoff.new; echo "sudo rule refused"; exit 1; }
# 2. the approvals account: its settings (root only), one device, a seat in the owner's Assistant chat (invited in
#    step 75). Older installs had a separate encrypted Approvals room and an encryption store; both go.
touch $HE; chmod 600 $HE
setv $HE HS "http://127.0.0.1:$PORT"; setv $HE GATE_USER "@approvals:$NAME"; setv $HE OWNER_ID "@$OWNER:$NAME"
setv $HE ROOM_ID "$(getv $MX ASSISTANT_ROOM)"; sed -i '/^PICKLE_KEY=/d; /^GATE_DEVICE=/d' $HE; rm -rf /var/lib/lite-handoff
[ -n "$(getv $HE WAIT_SECONDS)" ] || setv $HE WAIT_SECONDS 600
/opt/lite/bin/lite-handoff --setup || { echo "approvals could not join the Assistant chat"; exit 1; }
# 3. the tool in the assistant's settings (no extra Hermes prompt: the gate is the approval)
before=$(md5sum < $HH/config.yaml)
{ hd config set mcp_servers.frontier.command /usr/bin/python3 && hd config set mcp_servers.frontier.args '[/opt/lite/bin/lite-handoff-mcp]' && hd config set mcp_servers.frontier.timeout 2700; } >/dev/null \
  || { echo "the assistant's settings refused the Frontier tool"; exit 1; }
# a new tool text or setting reaches the assistant only after a restart
if { [ "$before" != "$(md5sum < $HH/config.yaml)" ] || [ "$tool_before" != "$(md5sum < /opt/lite/bin/lite-handoff-mcp)" ]; } && systemctl is-active -q lite-assistant-chat; then
  systemctl stop lite-assistant-chat; systemctl start lite-assistant-chat
fi
echo "handoff: gate $(stat -c '%U %a' /opt/lite/bin/lite-handoff), jobs folder $(stat -c '%U:%G %a' /srv/lite-frontier), driver may run: $(sudo -l -U $U 2>/dev/null | grep -c lite-handoff) rule, frontier tool: $( [ -f /home/frontier/.claude/.credentials.json ] && echo 'Claude Code (signed in)' || { [ -f /home/frontier/.codex/auth.json ] && echo 'Codex (signed in)' || echo 'not signed in yet (Frontier tile: type claude)'; })"
echo "STEP 77 OK"
