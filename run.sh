#!/bin/bash
# For working on a test server from here: copies this folder to the server and runs the installer, or
# single steps, as root over SSH. The owner never uses this; they run install.sh on the server itself.
#   ./run.sh HOST KEY                          full install (bash install.sh on the server)
#   ./run.sh HOST KEY 55-accounts 60-connect   only these steps
set -euo pipefail
HOST=${1:?host}; KEY=${2:?ssh key}; shift 2
cd "$(dirname "$0")"
PORT=${PORT:-22}
SSH="ssh ${SSH_OPTS:-} -p $PORT -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
$SSH "root@$HOST" 'command -v rsync >/dev/null || (apt-get -qq update && apt-get -y -qq install rsync) >/dev/null; install -d -m 755 /root/wizard-lite /opt/lite-src'
rsync -a --delete --exclude .git --exclude __pycache__ -e "$SSH" ./ "root@$HOST:/root/wizard-lite/"
if [ $# = 0 ]; then
  $SSH "root@$HOST" 'bash /root/wizard-lite/install.sh'
else
  $SSH "root@$HOST" 'rsync -a --delete --exclude __pycache__ /root/wizard-lite/payload /root/wizard-lite/tests /opt/lite-src/'
  for step in "$@"; do
    echo "#### $step"
    $SSH "root@$HOST" "bash /root/wizard-lite/steps/$step.sh"
  done
fi
