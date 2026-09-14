#!/bin/bash
# Run as root, on the NanoPi itself.
# Purpose: route THIS BOX's own outbound traffic through NordVPN. This is not
# a remote-access VPN into the LAN - see README for that distinction.
set -euo pipefail

LAN_SUBNET="${LAN_SUBNET:-192.168.0.0/24}"
VPN_COUNTRY="${VPN_COUNTRY:-}"   # e.g. "South_Korea" - empty picks fastest server

curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh -o /tmp/nordvpn-install.sh
sh /tmp/nordvpn-install.sh -n
systemctl enable --now nordvpnd

if [ -n "${NORDVPN_TOKEN:-}" ]; then
  nordvpn login --token "$NORDVPN_TOKEN"
else
  echo
  echo "No NORDVPN_TOKEN set - log in manually now:"
  echo "  nordvpn login"
  echo "(open the printed URL in a browser, or generate an access token at"
  echo " my.nordaccount.com and re-run: NORDVPN_TOKEN=... $0)"
  exit 1
fi

# Without this, the SBC's own LAN-facing services (ssh, pi-hole, cups) become
# unreachable once the tunnel is up and killswitch is on.
nordvpn allowlist add subnet "$LAN_SUBNET"
nordvpn set killswitch on
nordvpn set autoconnect on

# The router's own DNS (used for the box's OS-level lookups, e.g. apt) gets
# blocked by Nord's firewall once connected, even with the LAN subnet
# allowlisted - only ICMP/routing is exempted, not the router's port 53.
# Point the system resolver at a public DNS directly instead. (Pi-hole itself
# is unaffected - it already uses PIHOLE_DNS_1/2 directly, not the router.)
sed -i 's/^#*DNS=.*/DNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
grep -q '^DNS=' /etc/systemd/resolved.conf || echo 'DNS=1.1.1.1 1.0.0.1' >> /etc/systemd/resolved.conf
systemctl restart systemd-resolved

if [ -n "$VPN_COUNTRY" ]; then
  nordvpn connect "$VPN_COUNTRY"
else
  nordvpn connect
fi

nordvpn status
