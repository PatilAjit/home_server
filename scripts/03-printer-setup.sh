#!/bin/bash
# Run as root, on the NanoPi itself. Printer must already be plugged in via USB.
set -euo pipefail

PRINTER_NAME="${PRINTER_NAME:-Epson-ET-2850}"
MODEL_HINT="${PRINTER_MODEL_HINT:-ET-2850}"   # substring to match in the model name

DEBIAN_FRONTEND=noninteractive apt-get -y install cups printer-driver-escpr
systemctl enable --now cups

USB_URI=$(lpinfo -v 2>/dev/null | grep -i usb | grep -i EPSON | awk '{print $2}' | head -1)
if [ -z "$USB_URI" ]; then
  echo "No USB-attached Epson printer found. Is it plugged in? (check: lsusb)" >&2
  exit 1
fi
echo "Found printer at: $USB_URI"

# Newer CUPS deprecated the -m (query cups-driverd for a PPD by model string)
# path for compiled drivers like escpr - it fails silently ("empty PPD file").
# Generate the PPD directly from the driver binary instead.
PPD_URI=$(lpinfo -m 2>/dev/null | grep -i "$MODEL_HINT" | grep -i escpr | head -1 | awk '{print $1}')
if [ -z "$PPD_URI" ]; then
  echo "No escpr PPD found matching '$MODEL_HINT'. Run 'lpinfo -m | grep -i escpr' to see options." >&2
  exit 1
fi
echo "Using PPD: $PPD_URI"

PPD_FILE="/root/${PRINTER_NAME}.ppd"
/usr/lib/cups/driver/escpr cat "$PPD_URI" > "$PPD_FILE"

lpadmin -p "$PRINTER_NAME" -E -v "$USB_URI" -P "$PPD_FILE" -L "Home Server" -D "$(basename "$MODEL_HINT") printer"
lpadmin -d "$PRINTER_NAME"
cupsenable "$PRINTER_NAME"
cupsaccept "$PRINTER_NAME"
lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true

# Allow the printer/jobs to be managed from any browser on the LAN, not just
# localhost. Admin actions still require a login (any user in the lpadmin
# group, or root).
cupsctl --remote-any --share-printers --remote-admin

echo
echo "Printer '$PRINTER_NAME' added and shared. CUPS web UI: http://<this-box-ip>:631"
lpstat -p -d
