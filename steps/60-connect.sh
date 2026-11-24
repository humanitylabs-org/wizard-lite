#!/bin/bash
# Step 60: hand each connector to the driver's Hermes.
#   - copies each app's credential from /etc/lite/connectors.env into the driver's own secrets file
#   - lists one MCP server per app in the driver's settings, each with a short list of allowed tools
#     (the connectors offer 189 tools between them; a mid-size private model does better with about 50)
#   - no deletes are handed over: the assistant can read, add and change, never remove
# Idempotent. Only apps whose credential exists get wired, so a failed app step never breaks the others.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
U=driver; HH=/home/$U/.hermes; CONN=/etc/lite/connectors.env
N=/opt/lite/node/bin/node; M=/opt/lite/connectors/node_modules
as() { local u=$1; shift; sudo -iu "$u" bash -lc "$*"; }
cfg() { /opt/lite/bin/hermes-driver config set "$1" "$2" >/dev/null || { echo "config set $1 refused"; return 1; }; }
has() { grep -qE "^$1=.+" $CONN 2>/dev/null; }

# 1. secrets: replace the connector block in the driver's .env
T=$(mktemp); sed '/^# lite connectors (start)/,/^# lite connectors (end)/d' $HH/.env > $T
{ echo "# lite connectors (start)"; grep -E '^[A-Z_]+=' $CONN; echo "# lite connectors (end)"; } >> $T
install $( [ -f /home/driver/.hermes/.managed ] && echo "-o fixer -g driver -m 640" || echo "-o driver -g driver -m 600") $T $HH/.env; rm -f $T   # owner: step 78
install -d -o $U -g $U -m 700 /home/$U/.local/share/lite /home/$U/.local/share/lite/actual /home/$U/.config/navidrome-mcp

# 2. one MCP server per app
server() {  # name, script, extra-arg-or-empty, "ENV1 ENV2=literal ...", "tool1, tool2, ..."
  local n=$1 script=$2 arg=$3 envs=$4 tools=$5 e k v
  cfg mcp_servers.$n.command "$N"
  if [ -n "$arg" ]; then cfg mcp_servers.$n.args "[$script, $arg]"; else cfg mcp_servers.$n.args "[$script]"; fi
  for e in $envs; do
    case $e in *=*) k=${e%%=*}; v="\"${e#*=}\"";; *) k=$e; v="\${$e}";; esac   # literals are quoted so true/false stay text
    cfg mcp_servers.$n.env.$k "$v"
  done
  cfg mcp_servers.$n.tools.include "[$tools]"
  cfg mcp_servers.$n.tools.resources false
  cfg mcp_servers.$n.tools.prompts false
  cfg mcp_servers.$n.timeout 120
  wired="$wired $n"
}
wired=""
has IMMICH_API_KEY && server photos $M/immich-mcp/dist/mcp-bin.js "" \
  "IMMICH_BASE_URL IMMICH_API_KEY IMMICH_ALLOW_WRITES=true" \
  "immich_ping, immich_get_server_statistics, immich_list_assets, immich_get_asset, immich_search_metadata, immich_search_smart, immich_list_albums, immich_get_album, immich_create_album, immich_add_assets_to_album, immich_list_people, immich_get_person_assets, immich_update_asset"
has ACTUAL_BUDGET_SYNC_ID && server budget $M/actual-mcp/build/index.js "--enable-write" \
  "ACTUAL_SERVER_URL ACTUAL_PASSWORD ACTUAL_BUDGET_SYNC_ID ACTUAL_DATA_DIR=/home/$U/.local/share/lite/actual" \
  "get-accounts, get-transactions, get-grouped-categories, get-payees, get-budget-month, spending-by-category, monthly-summary, budget-vs-actual, net-worth, create-transaction, update-transaction, create-category, set-budget-amount"
has NAVIDROME_PASSWORD && server music $M/navidrome-mcp/dist/index.js "" \
  "NAVIDROME_URL NAVIDROME_USERNAME NAVIDROME_PASSWORD WEBUI_ENABLED=false" \
  "test_connection, search_all, search_songs, search_albums, search_artists, get_album, list_playlists, get_playlist_tracks, create_playlist, add_tracks_to_playlist, star_item, list_recently_played, list_most_played"
has CALDAV_PASSWORD && server calendar $M/dav-mcp/src/server-stdio.js "" \
  "CALDAV_SERVER_URL CALDAV_USERNAME CALDAV_PASSWORD" \
  "list_calendars, list_events, calendar_query, create_event, update_event, list_addressbooks, list_contacts, addressbook_query, create_contact, update_contact, list_todos, create_todo, update_todo"
# mail_send is left out: sending is irreversible and the connector wants a confirmation step Hermes cannot show;
# the assistant drafts, the owner sends (PLAN.md open question).
has JMAP_BEARER_TOKEN && server mail $M/@bryanberger/jmap-mcp/dist/index.js "" \
  "JMAP_SESSION_URL JMAP_BEARER_TOKEN" \
  "mail_folders, mail_search, mail_read, mail_attachment_fetch, mail_identities, mail_compose, mail_organize, vacation_manage"
echo "wired:$wired"
echo "$wired" | tr ' ' '\n' | grep -v '^$' > /etc/lite/connected-apps; chmod 640 /etc/lite/connected-apps

# 3. nothing to reload: the assistant runs in the terminal and reads these settings each time it starts
#    (step 70 writes the links file the tour reads)

# 4. connectors only: the assistant loses its own terminal, file and code-running tools, so it cannot read the
#    connector credentials or app files and can only act through the allowed connector tools. Everything else a
#    private assistant does not need goes too (web, browser, computer use, images, speech, vision, helpers,
#    scheduled jobs, cloud connections). What stays: the app connectors, memory, to-do, questions, earlier chats,
#    and skills (for the tour).
OFF="terminal file code_execution web browser computer_use image_gen tts vision delegation cronjob connections"
/opt/lite/bin/hermes-driver tools disable $OFF >/dev/null
echo "assistant tools on: $(/opt/lite/bin/hermes-driver tools list | sed -n '/Built-in/,/Plugin/p' | grep ' enabled ' | awk '{print $3}' | tr '\n' ' ')"
# 5. Hermes's stock skills (coding, GitHub and so on) are not for a private assistant; Hermes's own switch removes
#    them and stops updates from putting them back. The tour skill lives outside that folder and stays.
/opt/lite/bin/hermes-driver skills opt-out --remove --yes >/dev/null 2>&1 || echo "stock skills could not be removed"
echo "assistant skills left: $(/opt/lite/bin/hermes-driver skills list | grep -c 'enabled *│' || true)"
echo "STEP 60 OK"
