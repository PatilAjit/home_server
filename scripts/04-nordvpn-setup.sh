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

# NordLynx advertises MTU 1420 but the real path MTU is ~1390. Packets sized
# in between are silently dropped - the kernel thinks they fit so it never
# emits "fragmentation needed", and nothing tells the sender to back off. The
# symptom is deceptive: ping and DNS work fine while every TLS handshake hangs.
cat > /etc/udev/rules.d/99-nordlynx-mtu.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="nordlynx", RUN+="/usr/sbin/ip link set nordlynx mtu 1380"
EOF
udevadm control --reload-rules

# Nord's firewall explicitly drops DNS to any LAN address as an anti-leak
# measure ("block to LAN DNS" rules in its nftables table), so the router can
# no longer resolve for this box - which breaks apt. Use a public resolver
# directly. (Pi-hole is unaffected: it queries PIHOLE_DNS_1/2, not the router.)
sed -i 's/^#*DNS=.*/DNS=1.1.1.1 1.0.0.1/' /etc/systemd/resolved.conf
grep -q '^DNS=' /etc/systemd/resolved.conf || echo 'DNS=1.1.1.1 1.0.0.1' >> /etc/systemd/resolved.conf
systemctl restart systemd-resolved

if [ -n "$VPN_COUNTRY" ]; then
  nordvpn connect "$VPN_COUNTRY"
else
  nordvpn connect
fi

nordvpn status
