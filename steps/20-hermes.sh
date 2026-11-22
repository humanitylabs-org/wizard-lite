#!/bin/bash
# Step 20: stock Hermes for the driver user, pinned to the commit already proven on the Wingman server.
# Install only; phase 30 points it at the Tinfoil proxy, and step 70 asks the owner for the key.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR
HERMES_COMMIT=${HERMES_COMMIT:-26ced2f9fc13204caa7c86fed0438cdf684fdfd3}
U=driver
HH=/home/$U/.hermes

current=$(sudo -iu $U git -C "$HH/hermes-agent" rev-parse HEAD 2>/dev/null || true)
if [[ "$current" != "$HERMES_COMMIT"* ]]; then
  # raw.githubusercontent.com rate-limits VPS addresses, so read install.sh out of a clone.
  rm -rf /tmp/hermes-src
  git clone -q --filter=blob:none --no-checkout https://github.com/NousResearch/hermes-agent.git /tmp/hermes-src
  git -C /tmp/hermes-src show "$HERMES_COMMIT:scripts/install.sh" > /tmp/hermes-install.sh
  chmod 755 /tmp/hermes-install.sh; rm -rf /tmp/hermes-src
  if ! sudo -iu $U bash /tmp/hermes-install.sh --commit "$HERMES_COMMIT" --non-interactive \
        --skip-browser --skip-computer-use >/var/log/lite-hermes-install.log 2>&1; then
    tail -40 /var/log/lite-hermes-install.log; echo "hermes install failed"; exit 1
  fi
fi
touch /etc/lite/versions
sed -i '/^hermes=/d' /etc/lite/versions
echo "hermes=$HERMES_COMMIT" >> /etc/lite/versions

echo "== result"
sudo -iu $U bash -lc 'hermes --version' 2>&1 | sed -n 1,3p
echo "commit=$(sudo -iu $U git -C "$HH/hermes-agent" rev-parse HEAD)"
echo "driver sudo: $(sudo -l -U $U 2>&1 | grep -c "may run" || true)"
echo "driver docker: $(id -nG $U | grep -cw docker || true)"
echo "STEP 20 OK"
