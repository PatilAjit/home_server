#!/bin/bash
# Run as root, on the NanoPi itself, AFTER 04-nordvpn-setup.sh.
#
# Turns the second NIC into a VPN gateway port: anything plugged into it gets
# a DHCP lease from this box, uses pi-hole for DNS, and has its traffic NATed
# out through the NordVPN tunnel.
set -euo pipefail

GW_IFACE="${GW_IFACE:-enp1s0}"
GW_SUBNET="${GW_SUBNET:-192.168.100.0/24}"
GW_ADDR="${GW_ADDR:-192.168.100.1}"
DHCP_START="${DHCP_START:-192.168.100.50}"
DHCP_END="${DHCP_END:-192.168.100.200}"

# --- static address on the gateway port -------------------------------------
# Armbian's stock netplan claims every "e*" interface for DHCP. Its generated
# unit (10-netplan-all-eth-interfaces) sorts BEFORE 10-netplan-<iface>, and
# systemd-networkd applies the first match only - so the glob silently wins and
# the static address never lands. Narrow the glob to "end*" to stop that.
if grep -q 'name: "e\*"' /etc/netplan/10-dhcp-all-interfaces.yaml 2>/dev/null; then
  cp /etc/netplan/10-dhcp-all-interfaces.yaml /etc/netplan/10-dhcp-all-interfaces.yaml.bak
  sed -i 's|name: "e\*"|name: "end*"|' /etc/netplan/10-dhcp-all-interfaces.yaml
fi

cat > /etc/netplan/20-vpn-gateway.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $GW_IFACE:
      dhcp4: no
      dhcp6: no
      addresses:
        - $GW_ADDR/24
EOF
chmod 600 /etc/netplan/20-vpn-gateway.yaml
netplan apply

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpn-gateway.conf
sysctl -p /etc/sysctl.d/99-vpn-gateway.conf

DEBIAN_FRONTEND=noninteractive apt-get -y install nftables dnsmasq

# --- DHCP for the gateway port ----------------------------------------------
cat > /etc/dnsmasq.d/vpn-gateway.conf << EOF
# DHCP only, no DNS: pi-hole FTL already owns port 53 on all interfaces and
# answers queries arriving on $GW_ADDR, so these clients get ad-blocking too.
port=0

# bind-interfaces + interface= keeps this strictly on the gateway port. It must
# never serve DHCP on the WAN side - the house router is the DHCP server there,
# and two of them on one segment causes address conflicts.
interface=$GW_IFACE
bind-interfaces

dhcp-range=$DHCP_START,$DHCP_END,12h
dhcp-option=3,$GW_ADDR
dhcp-option=6,$GW_ADDR
EOF
systemctl restart dnsmasq

# Nord's killswitch firewall would otherwise swallow every DHCP request before
# dnsmasq sees it: its input chain is 'policy drop', and the only non-tunnel
# exception accepts source addresses in the private ranges. A DHCP client has
# no address yet, so it sends from 0.0.0.0 - matching nothing, it gets dropped.
# The symptom is baffling (packets visible in tcpdump, zero DHCP log entries),
# so allowlist the ports via Nord's own CLI, which survives reconnects.
nordvpn allowlist add port 67 protocol UDP
nordvpn allowlist add port 68 protocol UDP

# --- NAT + MSS clamping -----------------------------------------------------
cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
# Deliberately NO 'flush ruleset' here: nordvpnd maintains its own 'inet
# nordvpn' table and would be wiped by a global flush. Only our own table is
# replaced, so the two coexist and survive each other's reloads.
table inet vpn_gateway
delete table inet vpn_gateway

table inet vpn_gateway {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $GW_SUBNET oifname "nordlynx" masquerade
	}

	# The tunnel's real path MTU is below its advertised one, so clients would
	# stall on large packets. Rewrite MSS on SYNs to match the actual route MTU.
	chain forward_mss {
		type filter hook forward priority mangle; policy accept;
		oifname "nordlynx" tcp flags syn tcp option maxseg size set rt mtu
	}
}
EOF
nft -f /etc/nftables.conf
systemctl enable --now nftables

# netplan apply above restarts systemd-networkd, which FLUSHES the policy
# routing rules nordvpnd installed - the tunnel stays up but nothing routes
# into it, and the killswitch then blocks everything. Reconnect to rebuild them.
nordvpn disconnect >/dev/null 2>&1 || true
sleep 2
nordvpn connect "${VPN_COUNTRY:-}" || nordvpn connect

echo
echo "Gateway ready on $GW_IFACE ($GW_ADDR), handing out $DHCP_START-$DHCP_END."
echo "Nord's forward chain already permits traffic out to nordlynx, so no rules"
echo "need to be added to its table."
ip rule show
