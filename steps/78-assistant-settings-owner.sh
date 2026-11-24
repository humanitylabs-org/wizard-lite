#!/bin/bash
# Step 78 (TEST, see PLAN.md): the private assistant cannot change its own settings or its install; the fixer owns
# them. Plain file ownership plus Hermes's own stock write lock (a .managed marker), no custom code:
#   fixer-owned, driver may only read:  ~/.hermes/config.yaml, .env, SOUL.md, .managed, the Hermes install and its runtimes
#                                       (hermes-agent, tools, installs), plugins and hooks (code the gateway would load)
#   driver keeps writing what Hermes writes while it runs: state.db, sessions, memories, logs, cache, skills ...
#   /home/driver and ~/.hermes belong to the fixer with the sticky bit, so driver can add its own files there but
#   cannot delete, rename or replace the fixer's (a moved-away ~/.hermes would otherwise be a way around this).
#   The fixer changes the assistant's settings with: hermes-driver config set ... (also tools, update).
# Idempotent; run after every step that writes the assistant's settings.
set -uo pipefail
U=driver; F=fixer; HOMED=/home/$U; H=$HOMED/.hermes
[ -x $H/hermes-agent/.hermes/bin/hermes ] || { echo "Hermes is not installed (step 20)"; exit 1; }
install -m 755 -o root -g root /opt/lite-src/payload/hermes-driver /opt/lite/bin/hermes-driver

# 1. Hermes's own lock: it refuses to write settings, and stops resetting file modes to owner-only
printf 'lite\n' | install -m 644 -o $F -g $U /dev/stdin $H/.managed
# 2. homes: the fixer owns them, driver may add (group rwx) but not remove what is not its own (sticky)
chown $F:$U $HOMED $H; chmod 1770 $HOMED; chmod 3770 $H
# 3. the settings and the install
for f in config.yaml .env SOUL.md; do [ -e $H/$f ] && { chown $F:$U $H/$f; chmod 640 $H/$f; }; done
for d in hermes-agent tools installs plugins hooks backups; do
  [ -d $H/$d ] || install -d -o $F -g $U -m 750 $H/$d
  chown -R -h $F:$U $H/$d; chmod -R u+rwX,g+rX,g-w,o-rwx $H/$d
done
# the fixer's Hermes (hermes-driver) looks into the assistant's runtime folders when it starts, and only looks
id -nG $F | grep -qw $U || usermod -aG $U $F
for d in cron sessions logs logs/curator memories pairing image_cache audio_cache skills; do [ -d $H/$d ] && chmod g+rx,g-w $H/$d; done
# Hermes's launcher takes a lock and leaves a lease (a "still in use" note) in its install state every time it
# starts, so exactly those lock files and lease folders stay writable for driver; nothing they hold is code
find $H/installs \( -name .install.lock -o -name .prepare.lock -o -name .lock \) -type f -exec chmod g+w {} +
find $H/installs -type d -name .leases -exec chmod g+ws {} +
find $H/installs -type d -exec chmod g+s {} +
# the command line starts Hermes from the install (step 75's service does too); driver's ~/.local stays its own
for b in hermes hermes-acp hermes-agent; do [ -e $HOMED/.local/bin/$b ] && chown -h $F:$U $HOMED/.local/bin/$b && chmod 755 $HOMED/.local/bin/$b; done
# 4. proof
w() { sudo -u $U test -w "$1" && echo writable || echo read-only; }
r=$(sudo -iu $U bash -lc "hermes config set display.lite_lock_probe 1" 2>&1 | tail -1)
echo "assistant settings: config.yaml $(w $H/config.yaml), .env $(w $H/.env), install $(w $H/hermes-agent/hermes_cli/config.py) for driver; owner $(stat -c %U $H/config.yaml)"
echo "driver's own 'hermes config set': $(grep -q lite_lock_probe $H/config.yaml && echo 'CHANGED THE SETTINGS' || echo refused) (${r:0:90})"
echo "fixer can change them: $(sudo -u $F test -w $H/config.yaml && echo yes || echo no); driver's hermes starts: $(sudo -iu $U hermes --version 2>&1 | head -1 | cut -c1-40)"
grep -q lite_lock_probe $H/config.yaml && exit 1
echo "STEP 78 OK"
