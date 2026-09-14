#!/bin/bash
# Run as root, on the NanoPi itself.
set -euo pipefail

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confold' upgrade
apt-get -y autoremove
apt-get clean

echo
echo "Upgrade complete. Check 'dmesg | grep -iE \"ext4|error\"' after the next reboot"
echo "before trusting the filesystem - this board previously hit real SD card"
echo "corruption (bad block bitmap) right after a kernel/u-boot upgrade + reboot."
echo "Reboot now with: reboot"
