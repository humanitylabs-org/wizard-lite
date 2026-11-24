# Sourced by steps 75 and 76: the owner's plain (unencrypted) chats with the agents' accounts. Miguel's choice: the
# security boundary is Tailscale plus his own server, so no end-to-end encryption, no identity checks, no recovery
# key. Conduit refuses encryption (step 75), and a chat still encrypted from an older install is replaced by a new
# plain one. Idempotent: each chat is made once and its id kept in matrix.env.
#   lite_dm HOMESERVER BOT_LOCALPART BOT_PASSWORD KEY_IN_MATRIX_ENV DISPLAY_NAME OWNER_MXID [MORE_MXIDS...]
# Prints the room id. Logs in as the bot with a fixed setup device and logs that device out again.
mx_login() {  # mx_login HS USER PASSWORD -> access token of a fixed setup device
  jq -cn --arg u "$2" --arg p "$3" '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p,device_id:"LITESETUP",initial_device_display_name:"installer (logs out again)"}' \
    | curl -s -m 20 -H 'content-type: application/json' -d @- "$1/_matrix/client/v3/login" | jq -r '.access_token // empty'
}
mx() {  # mx METHOD PATH [JSON], with $hs and $tok of the caller
  curl -s -m 20 -X "$1" -H @<(printf 'Authorization: Bearer %s' "$tok") -H 'content-type: application/json' ${3:+-d "$3"} "$hs/_matrix/client/v3$2"
}
uri() { jq -rn --arg s "$1" '$s|@uri'; }
encrypted() { [ -n "$(mx GET "/rooms/$(uri "$1")/state/m.room.encryption" | jq -r '.algorithm // empty')" ]; }

lite_dm() {
  local hs=$1 bot=$2 key=$4 name=$5 owner=$6 tok room m u
  tok=$(mx_login "$hs" "$bot" "$3"); [ -n "$tok" ] || { echo "lite_dm: $bot does not log in" >&2; return 1; }
  shift 5
  mx PUT "/profile/$(uri "@$bot:${owner#*:}")/displayname" "$(jq -cn --arg n "$name" '{displayname:$n}')" >/dev/null
  room=$(grep -E "^$key=" /etc/lite/matrix.env | tail -1 | cut -d= -f2-); m=""
  [ -n "$room" ] && m=$(mx GET "/rooms/$(uri "$room")/state/m.room.member/$(uri "$owner")" | jq -r '.membership // empty')
  [ -n "$room" ] && encrypted "$room" && { mx POST "/rooms/$(uri "$room")/leave" '{}' >/dev/null; m=""; }  # an old encrypted chat
  if [ "$m" != join ] && [ "$m" != invite ]; then
    room=$(mx POST /createRoom "$(jq -cn --arg n "$name" '{preset:"trusted_private_chat", is_direct:true, name:$n, invite:$ARGS.positional}' --args "$@")" | jq -r '.room_id // empty')
    [ -n "$room" ] && { sed -i "/^$key=/d" /etc/lite/matrix.env; printf '%s=%s\n' "$key" "$room" >> /etc/lite/matrix.env; }
  fi
  for u in "$@"; do   # everyone who belongs in the chat is in it, or invited
    m=$(mx GET "/rooms/$(uri "$room")/state/m.room.member/$(uri "$u")" | jq -r '.membership // empty')
    [ "$m" = join ] || [ "$m" = invite ] || mx POST "/rooms/$(uri "$room")/invite" "$(jq -cn --arg u "$u" '{user_id:$u}')" >/dev/null
  done
  mx POST /logout '{}' >/dev/null
  [ -n "$room" ] && echo "$room"
}

# lite_owner_tidy HS OWNER_LOCALPART OWNER_PASSWORD ROOM...: puts the owner's account in the given chats (Element X
# then opens straight onto them, no invites to accept) and leaves and forgets every encrypted room it is still in
# (dead here: Conduit refuses encrypted messages). The owner's own plain rooms are left alone.
lite_owner_tidy() {
  local hs=$1 tok r
  tok=$(mx_login "$1" "$2" "$3"); [ -n "$tok" ] || { echo "lite_owner_tidy: the owner does not log in" >&2; return 1; }
  shift 3
  for r in "$@"; do [ -n "$r" ] && mx POST "/rooms/$(uri "$r")/join" '{}' >/dev/null; done
  for r in $(mx GET /joined_rooms | jq -r '.joined_rooms[]?'); do
    encrypted "$r" && { mx POST "/rooms/$(uri "$r")/leave" '{}' >/dev/null; mx POST "/rooms/$(uri "$r")/forget" '{}' >/dev/null; }
  done
  mx POST /logout '{}' >/dev/null
}
