#!/bin/bash
# Writes and applies the three firewall rules. Part of the installer (steps 05 and 70 call it); root only.
# Reads /etc/lite/owner-devices (one line per device: Tailscale addresses, then "# name") and (re)applies
# our own nftables table. Docker's rules are never flushed.
#   1. Internet: nothing is reachable except SSH (until Tailscale SSH is proven) and Tailscale's own UDP port.
#      Docker-published app ports are blocked on the public interface too (a plain INPUT rule would miss them).
#   2. Tailscale: only the owner's listed devices reach the server and its apps. No list means no device.
#      Tailscale SSH is answered inside Tailscale itself and is not affected by the list.
#   3. Linux users: the frontier user cannot connect to anything on this server, its apps, or any private or Tailscale
#      address. It keeps the internet and name lookups.
#   Also: the three browser terminals (ports 7681-7683, Caddy's 17681-17683) answer only over Tailscale, so no app
#   or program on this server can open one (the fixer's terminal has admin rights).
#   https: when /etc/lite/https-ports exists (written by payload/https.sh), each listed port arriving over Tailscale
#   is handed to Caddy's own port on this server. This happens before Docker's own forwarding, and the device
#   list below still applies, because the request keeps the address of the device that sent it.
#   bash firewall.sh          apply the rules from the device list
#   bash firewall.sh --arm    same, with a 3-minute rollback in case a hand change locks you out
set -euo pipefail
PUB=$(ip -o -4 route show default | awk '{print $5; exit}')
[ -n "$PUB" ] || { echo "no default interface"; exit 1; }
install -d -m 750 /etc/lite
touch /etc/lite/owner-devices
FUID=$(id -u frontier)
ips=$(sed 's/#.*//' /etc/lite/owner-devices | tr ' ' '\n' | grep -v '^$' || true)
OWN4=$(echo "$ips" | grep -v : | paste -sd, - || true)
OWN6=$(echo "$ips" | grep : | paste -sd, - || true)
HTTPS=$(awk 'NF==2 {printf "%s%s : %s", (n++ ? ", " : ""), $1, $2}' /etc/lite/https-ports 2>/dev/null || true)
TO_CADDY=""
[ -z "$HTTPS" ] || TO_CADDY="iifname \"tailscale0\" redirect to : tcp dport map { $HTTPS } comment \"https: to Caddy\""

cat > /etc/lite/firewall.nft <<EOF
table inet lite_fw
delete table inet lite_fw
table inet lite_fw {
  set owner4 { type ipv4_addr; ${OWN4:+elements = { $OWN4 \}} }
  set owner6 { type ipv6_addr; ${OWN6:+elements = { $OWN6 \}} }
  chain input {
    type filter hook input priority 0; policy drop;
    iifname != "tailscale0" tcp dport { 7681-7683, 17681-17683 } drop comment "browser terminals: only over Tailscale, never from this server or its apps"
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    iifname "tailscale0" ip saddr @owner4 accept
    iifname "tailscale0" ip6 saddr @owner6 accept
    iifname "docker0" accept
    iifname "br-*" accept
    meta l4proto { icmp, ipv6-icmp } accept
    iifname "$PUB" tcp dport 22 accept comment "ssh: remove once Tailscale SSH is proven"
    iifname "$PUB" udp dport 41641 accept comment "tailscale direct connections"
  }
  chain https {
    type nat hook prerouting priority dstnat - 10; policy accept;
    $TO_CADDY
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$PUB" ct state established,related accept
    iifname "$PUB" drop comment "no app port is reachable from the internet"
    iifname "tailscale0" ct state established,related accept
    iifname "tailscale0" ip saddr @owner4 accept
    iifname "tailscale0" ip6 saddr @owner6 accept
    iifname "tailscale0" drop comment "apps: only the owner's listed devices"
  }
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid $FUID jump frontier_out
  }
  chain frontier_out {
    ct state established,related accept
    ip daddr { 127.0.0.53, 127.0.0.54 } meta l4proto { tcp, udp } th dport 53 accept comment "name lookups"
    fib daddr type local reject comment "frontier: nothing on this server"
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } reject comment "frontier: no apps, no Tailscale devices"
    ip6 daddr { fc00::/7, fe80::/10 } reject
  }
}
EOF
chmod 644 /etc/lite/firewall.nft
nft -c -f /etc/lite/firewall.nft

if [ "${1:-}" = "--arm" ]; then
  # Safety net at install time: if this locks us out, the table is removed again after 3 minutes.
  systemctl stop lite-fw-rollback.timer lite-fw-rollback.service 2>/dev/null || true
  systemctl reset-failed lite-fw-rollback.service 2>/dev/null || true
  systemd-run --quiet --unit=lite-fw-rollback --on-active=180 /usr/sbin/nft delete table inet lite_fw
fi
systemctl restart lite-firewall
echo "firewall on $PUB: $(grep -c . /etc/lite/owner-devices) owner device(s) may open the apps"
