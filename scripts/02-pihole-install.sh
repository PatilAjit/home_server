#!/bin/bash
# Run as root, on the NanoPi itself, after 01-system-upgrade.sh + reboot.
set -euo pipefail

IFACE="${PIHOLE_INTERFACE:-end0}"
STATIC_IP="${PIHOLE_IP:-192.168.0.116/24}"
DNS1="${PIHOLE_DNS_1:-1.1.1.1}"
DNS2="${PIHOLE_DNS_2:-1.0.0.1}"

# Free port 53: systemd-resolved's stub listener only binds 127.0.0.53, but
# pi-hole's installer expects the port free and will otherwise get confused.
sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
grep -q '^DNSStubListener' /etc/systemd/resolved.conf || echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=$IFACE
IPV4_ADDRESS=$STATIC_IP
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=all
PIHOLE_DNS_1=$DNS1
PIHOLE_DNS_2=$DNS2
DNSSEC=true
REV_SERVER=false
EOF

curl -sSL https://install.pi-hole.net -o /tmp/pihole-install.sh
# sha256 of the official installer at time of writing - if this mismatches,
# STOP and inspect the script before running (pi-hole's install.net endpoint
# could theoretically change, or something on the network path could tamper
# with it): bd558069a224910e4b6264a44e2cd4bdb5a8fb45d232e10e6fb91dd804590dc7
sha256sum /tmp/pihole-install.sh
chmod +x /tmp/pihole-install.sh
/tmp/pihole-install.sh --unattended

echo
echo "Pi-hole installed. Set the admin password with:"
echo "  pihole setpassword '<your-password>'"
echo "Admin UI: http://<this-box-ip>/admin"
echo
echo "Remember to point your router's DHCP DNS setting at this box's IP so"
echo "LAN devices actually use pi-hole for ad-blocking - that step can't be"
echo "automated from here, it's a router-side change."
