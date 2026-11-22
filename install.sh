#!/bin/bash
# WizardOS lite: the installer, and the only thing of ours the owner ever runs. As root on a fresh Debian 13:
#   curl -fsSL https://raw.githubusercontent.com/humanitylabs-org/wizard-lite/main/install.sh | bash
# or, from a copy of this folder:  bash install.sh
# It runs the steps in steps/ in order, each printing what it did, and writes everything to
# /var/log/lite-install.log. The last step asks the owner three things in this terminal: Tailscale sign-in,
# which devices may open the apps, and a Tinfoil key. Safe to run again: every step skips what is already
# done, and running it again is how the device list or the key is changed.
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "Run this as root."; exit 1; }
. /etc/os-release 2>/dev/null || true
[ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] || { echo "This installer is for Debian 13 (found: ${PRETTY_NAME:-unknown})."; exit 1; }

# Started through "curl ... | bash": there is no folder yet. Fetch it, then start again from the folder with
# the terminal attached, so the questions at the end can be answered.
SELF=${BASH_SOURCE[0]:-}
if [ -z "$SELF" ] || [ ! -d "$(dirname "$SELF")/steps" ]; then
  D=/root/wizard-lite
  rm -rf "$D.new" && mkdir -p "$D.new"
  curl -fsSL "${LITE_TARBALL:-https://github.com/humanitylabs-org/wizard-lite/archive/refs/heads/main.tar.gz}" | tar -xz --strip-components=1 -C "$D.new" \
    || { echo "Could not download the installer."; exit 1; }
  [ -f "$D.new/install.sh" ] && [ -d "$D.new/steps" ] || { echo "The download is not the installer."; exit 1; }
  rm -rf "$D" && mv "$D.new" "$D"
  if (exec </dev/tty) 2>/dev/null; then exec bash "$D/install.sh" </dev/tty; else exec bash "$D/install.sh"; fi
fi
cd "$(dirname "$SELF")" || exit 1
LOG=/var/log/lite-install.log
exec > >(tee -a "$LOG") 2>&1
echo "=== WizardOS lite install, $(date -u '+%Y-%m-%d %H:%M UTC'), host $(hostname)"

# the files the steps lay down (firewall rules, tour skill, Pi instructions) and the test list
install -d -m 755 /opt/lite-src
rm -rf /opt/lite-src/payload /opt/lite-src/tests && cp -a payload tests /opt/lite-src/   # cp: a fresh Debian has no rsync yet
install -d -m 750 /etc/lite

# Steps 55 and 57 set up the owner's account in each app; one app refusing must not stop the rest, and
# step 60 only connects the apps whose account exists. Step 70 is the owner's three questions, which can be
# answered on a later run. Every other step must succeed.
SOFT=" 55 57 70 "
failed=""; incomplete=""
for s in steps/[0-9][0-9]-*.sh; do
  n=$(basename "$s" | cut -c1-2); name=$(basename "$s" .sh)
  printf '\n#### %s (%s)\n' "$name" "$(date -u +%H:%M:%S)"
  if bash "$s"; then continue; fi
  if [[ "$SOFT" == *" $n "* ]]; then echo "#### $name: incomplete, going on"; incomplete="$incomplete $name"
  else echo "#### $name FAILED. Fix the cause, then run: bash install.sh (it continues where it stopped)"; failed=$name; break; fi
done

echo
echo "=== Result"
if [ -n "$failed" ]; then echo "Stopped at $failed. Details above and in $LOG."; exit 1; fi
[ -z "$incomplete" ] || echo "Not finished (see above):$incomplete. Run this installer again to finish."
echo "Your apps, open only on the devices you picked:"; sed 's/^/  /' /etc/lite/links.txt 2>/dev/null
echo "App login: the user name and password are in /etc/lite/owner.env (as fixer: sudo cat /etc/lite/owner.env)"
echo
echo "One terminal per Linux user. Open it in Tailscale (admin console, Machines, this server, SSH) with that"
echo "user name, or switch from this root terminal with su, for example: su - driver   (exit brings you back)"
echo "  driver     type: hermes            your private assistant (try: show me around)"
echo "  fixer      type: pi                the troubleshooter, the only user with admin rights"
echo "  frontier   type: claude or codex   frontier models, cut off from your apps; each asks you to sign in once"
echo "To change your devices or the key: sudo bash /root/wizard-lite/install.sh"
[ -z "$incomplete" ]
