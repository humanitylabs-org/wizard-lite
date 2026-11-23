#!/bin/bash
# Writes and applies the https front door. Part of the installer (steps 65 and 70 call it); root only.
# Stock Caddy (Debian's package) answers https for the apps page, each app and the three browser terminals,
# with a certificate it gets and renews by itself from this server's Tailscale (a *.ts.net name).
# The addresses stay the same, only with https:  https://NAME  https://NAME:APP-PORT  https://NAME:7681
#   - The firewall (payload/firewall.sh) hands each of these ports, when it arrives over Tailscale, to Caddy's
#     own port (the same number plus 10000; 80 and 443 both go to 10443). Caddy listens on the server itself,
#     not inside Tailscale, so the firewall still sees which device asked and only the picked devices get in.
#   - Caddy's terminal ports answer only over Tailscale (firewall), never to the server itself or its apps.
#     Its page and app ports also answer on the server itself, as the apps themselves already do.
#   - Plain http on any of these ports is answered with a redirect to https.
#   - The apps keep their own ports on the server (the connectors use 127.0.0.1:PORT); the terminals (ttyd) listen on a private
#     socket that only their own user and Caddy can open (see payload/terminal.sh).
# Until the server is on Tailscale it has no name, so nothing is written and Caddy stays off.
set -euo pipefail
NAME=$(tailscale status --json 2>/dev/null | jq -r 'if .BackendState == "Running" then .Self.DNSName // "" else "" end' | sed 's/\.$//')
CF=/etc/caddy/Caddyfile
PORTS=/etc/lite/https-ports
if [ -z "$NAME" ]; then echo "https: added once the server is on your Tailscale"; exit 0; fi

# port the owner opens | Caddy's own port | where Caddy passes it on
map=$(
  echo "443 10443 127.0.0.1:80"
  jq -r '.[] | "\(.port) \(.port + 10000) 127.0.0.1:\(.port)"' /etc/lite/apps.json
  echo "7681 17681 unix//run/lite-terminal/driver/ttyd.sock"
  echo "7682 17682 unix//run/lite-terminal/fixer/ttyd.sock"
  echo "7683 17683 unix//run/lite-terminal/frontier/ttyd.sock"
)
new=$(
  echo "# Written by the WizardOS lite installer (payload/https.sh). Running the installer again rewrites it."
  echo "{"
  echo "	admin off"
  echo "	auto_https disable_redirects"
  echo "	servers {"
  echo "		listener_wrappers {"
  echo "			http_redirect"
  echo "			tls"
  echo "		}"
  echo "	}"
  echo "}"
  while read -r port own to; do
    printf '\nhttps://%s:%s {\n\treverse_proxy %s\n}\n' "$NAME" "$own" "$to"
  done <<< "$map"
)
newports=$( (echo "80 10443"; awk '{print $1, $2}' <<< "$map") )

# Caddy may fetch the certificate for this server's name from Tailscale (read when tailscaled starts).
if ! grep -qx 'TS_PERMIT_CERT_UID=caddy' /etc/default/tailscaled 2>/dev/null; then
  echo 'TS_PERMIT_CERT_UID=caddy' >> /etc/default/tailscaled
  systemctl restart tailscaled
  for _ in $(seq 1 30); do [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" = Running ] && break; sleep 2; done
fi

changed=0
if [ "$new" != "$(cat "$CF" 2>/dev/null)" ]; then
  printf '%s\n' "$new" > "$CF.new"; caddy validate --adapter caddyfile --config "$CF.new" >/dev/null 2>&1 \
    || { caddy validate --adapter caddyfile --config "$CF.new"; rm -f "$CF.new"; exit 1; }
  mv "$CF.new" "$CF"; chmod 644 "$CF"; changed=1
fi
if [ "$newports" != "$(cat "$PORTS" 2>/dev/null)" ]; then
  printf '%s\n' "$newports" | install -m 644 /dev/stdin "$PORTS"
  bash /opt/lite-src/payload/firewall.sh >/dev/null
fi
systemctl enable -q caddy
# A restart closes open terminal connections, so only when the settings changed (or Caddy is not running).
if [ $changed = 1 ] || ! systemctl is-active -q caddy; then systemctl restart caddy; fi
systemctl is-active -q caddy || { echo "https: Caddy did not start"; journalctl -u caddy -n 20 --no-pager; exit 1; }
# the certificate: ask Caddy for the page and check the answer (up to a minute on the first run)
for _ in $(seq 1 30); do
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' --resolve "$NAME:10443:127.0.0.1" "https://$NAME:10443/" || true)
  [ "$code" != 000 ] && break; sleep 2
done
[ "$code" != 000 ] || { echo "https: no valid certificate for $NAME yet"; exit 1; }
echo "https: https://$NAME (page), $(jq length /etc/lite/apps.json) apps and 3 terminals, certificate valid"
