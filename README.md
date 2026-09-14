# Home Server Setup

Reproducible setup for the homelab NanoPi R4S. If the SD card ever dies again
(it has, once - see [History](#history)), flash a fresh card and re-run these
scripts in order instead of redoing everything by hand.

## Hardware

- SBC: NanoPi R4S, Rockchip RK3399, 4GB RAM
- Storage: microSD (Kingston, as of 2026-09 - the original card failed, see History)
- OS: Armbian (Ubuntu-based), aarch64
- Printer: Epson ET-2850/L4260 EcoTank, USB-attached
- Static LAN IP: 192.168.0.116 (via router DHCP reservation)

## What's set up

1. **SSH key auth** - key-based login for root (password auth left enabled by choice)
2. **Pi-hole** - LAN-wide ad blocking, upstream DNS = Cloudflare (1.1.1.1/1.0.0.1)
3. **CUPS print server** - shares the Epson ET-2850 over the network
4. **NordVPN** - routes the box's *own* outbound traffic through NordVPN
   (NordLynx/WireGuard). This is **not** a remote-access VPN into the LAN -
   it's the SBC acting as its own VPN client. (NordVPN Meshnet would be the
   tool for LAN remote-access instead, if that's ever wanted - not set up here.)

## Rebuild steps (fresh SD card)

1. Flash Armbian for NanoPi R4S onto the new card, boot it, note its IP/root password.
2. From your workstation:
   ```
   HOMESERVER_HOST=192.168.0.116 HOMESERVER_PASSWORD='<root password>' \
     bash scripts/00-push-ssh-key.sh
   ```
3. From here on, run the rest **on the box itself** (`ssh root@<ip>`), or scp
   the `scripts/` directory over first:
   ```
   bash scripts/01-system-upgrade.sh
   reboot
   # after it comes back up, check for filesystem errors before continuing:
   dmesg | grep -iE 'ext4|error'
   ```
4. ```
   bash scripts/02-pihole-install.sh
   pihole setpassword '<choose a password>'
   ```
   Then point your router's DHCP DNS setting at this box's IP - that step is
   router-side and can't be scripted from here.
5. ```
   bash scripts/03-printer-setup.sh
   ```
6. ```
   NORDVPN_TOKEN='<token from my.nordaccount.com>' VPN_COUNTRY=South_Korea \
     bash scripts/04-nordvpn-setup.sh
   ```

## Secrets

Nothing in this repo contains real credentials. Keep your own copy of:
- root password
- Pi-hole admin password
- NordVPN access token (generate/revoke at my.nordaccount.com)

in a local, gitignored file (see `secrets.env.example` for the shape) or your
password manager - never commit them.

## History

- **2026-08/09**: original SD card hit `ext4` bad-block-bitmap corruption
  (block group 240) after a routine `apt upgrade` + reboot - root filesystem
  kept auto-remounting read-only. Re-flashing the *same* card reproduced the
  identical error at the identical block group, which ruled out a software
  cause: it was a physical defect in that specific card. Replaced with a new
  Kingston card and the same upgrade completed cleanly with no errors -
  confirms the failure was hardware, not this setup process.
- Lesson: if this ever recurs on the *replacement* card too, suspect the SD
  card slot/controller rather than the card itself.
