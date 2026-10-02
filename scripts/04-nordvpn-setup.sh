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
# symptom is deceptive: ping and DNS work fine while every TLS handshake hangs,
# so pages half-load or time out while the VPN looks perfectly healthy.
#
# Two defences, because neither alone is enough:
#
#   1. MSS clamping (below) - fixes all TCP. This is the load-bearing fix: it
#      works immediately on reconnect and is immune to the MTU race.
#   2. An MTU timer - nordvpnd re-asserts 1420 *after* the interface appears,
#      beating any udev rule, so a periodic enforcer is the only reliable way.
#      Only UDP/QUIC needs this, which is why the 60s convergence is tolerable.
#
# A fixed MSS is used rather than 'rt mtu', which would read the bogus 1420 and
# clamp to 1380 - still too big. 1340 + 40 bytes of headers fits the real PMTU.
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
# Deliberately NO 'flush ruleset': nordvpnd maintains its own 'inet nordvpn'
# table and would be wiped by a global flush. Only our table is replaced, so
# the two coexist and survive each other's reloads.
table inet vpn_gateway
delete table inet vpn_gateway

table inet vpn_gateway {
	chain output_mss {
		type filter hook output priority mangle; policy accept;
		oifname "nordlynx" tcp flags syn tcp option maxseg size set 1340
	}
}
EOF
nft -f /etc/nftables.conf
systemctl enable --now nftables

cat > /usr/local/sbin/nordlynx-mtu.sh << 'EOF'
#!/bin/sh
[ -d /sys/class/net/nordlynx ] || exit 0
[ "$(cat /sys/class/net/nordlynx/mtu)" = "1380" ] && exit 0
exec /usr/sbin/ip link set nordlynx mtu 1380
EOF
chmod +x /usr/local/sbin/nordlynx-mtu.sh

cat > /etc/systemd/system/nordlynx-mtu.service << 'EOF'
[Unit]
Description=Enforce working MTU on the NordLynx tunnel
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nordlynx-mtu.sh
EOF

cat > /etc/systemd/system/nordlynx-mtu.timer << 'EOF'
[Unit]
Description=Periodically enforce NordLynx MTU
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nordlynx-mtu.timer

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
