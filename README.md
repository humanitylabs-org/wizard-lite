# WizardOS lite

One private server, stock apps, and three agents that each run as their own Linux user. This folder is the
installer that builds it. It is the only thing of ours the owner runs: there are no other commands.

## For the owner

1. Install Debian 13 on the server and open its terminal as root.
2. Paste one line and wait about ten minutes:

       curl -fsSL https://raw.githubusercontent.com/humanitylabs-org/wizard-lite/main/install.sh | bash

3. At the end it asks three things in the same terminal: open a Tailscale sign-in link, pick which of your
   devices may open the apps, paste a Tinfoil key.
4. One terminal per Linux user. Open it in Tailscale (admin console, Machines, the server, SSH) with the user
   name, or switch from the root terminal with `su - driver` (`exit` brings you back).
   - `driver`: type `hermes`, your private assistant.
   - `fixer`: type `pi`, the troubleshooter and the only user with admin rights.
   - `frontier`: type `claude` or `codex`, frontier models, cut off from your apps.

To change your devices or the key, run the installer again: `sudo bash /root/wizard-lite/install.sh`.

## What is in here

- `install.sh`: runs the steps in `steps/` in order, logs to /var/log/lite-install.log, safe to run again.
- `steps/NN-*.sh`: one step each, in plain bash, idempotent. Pinned versions are at the top of each. The last
  one, `70-owner.sh`, asks the three questions.
- `payload/`: files the installer lays down: the firewall rules, the private assistant's tour skill and Pi's
  one page of instructions. No commands.
- `tests/TEN.md` and `tests/ten.sh`: the ten-request pass/fail test. `tests/mcp_probe.py`: checks a connector
  without any AI.
- `run.sh`: for working on a test server from another machine (copies this folder over and runs the installer
  or single steps as root). The owner never needs it.
