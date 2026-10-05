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
5. **VPN gateway port** - the second NIC (`enp1s0`, 192.168.100.1/24) hands out
   DHCP leases and NATs anything plugged into it out through the tunnel, with
   Pi-hole as its DNS. Plug a device in and its traffic is VPN'd and ad-blocked,
   with no client-side configuration.

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
   NORDVPN_TOKEN='<token from my.nordaccount.com>' VPN_TARGET=Dedicated_IP \
     bash scripts/04-nordvpn-setup.sh
   ```
7. Optional - the VPN gateway port:
   ```
   VPN_TARGET=Dedicated_IP bash scripts/05-vpn-gateway.sh
   ```

`VPN_TARGET` takes anything `nordvpn connect` accepts: a country
(`United_States`), a city, a server hostname, or a group. `Dedicated_IP` pins
the account's dedicated address - see below.

## Dedicated IP

The account has a NordVPN dedicated IP (a fixed US/New York address, as opposed
to a shared server address). Connect with `nordvpn connect Dedicated_IP`;
`nordvpn groups` lists available groups and `nordvpn account` shows whether the
dedicated IP is still active on the subscription.

Two things to know:

- **Auto-connect must be given the target**, i.e. `nordvpn set autoconnect on
  Dedicated_IP`. Plain `autoconnect on` reconnects to whatever Nord picks after
  a reboot, silently dropping you onto a shared address.
- **`nordvpn status` does not show the dedicated IP.** It reports the server's
  shared entry IP. To confirm the egress address, query it directly:
  ```
  curl -s https://api.nordvpn.com/v1/helpers/ips/insights
  ```

## Secrets

Nothing in this repo contains real credentials. Keep your own copy of:
- root password
- Pi-hole admin password
- NordVPN access token (generate/revoke at my.nordaccount.com)

in a local, gitignored file (see `secrets.env.example` for the shape) or your
password manager - never commit them.

## Troubleshooting

Three non-obvious failure modes have bitten this box. All are handled by the
scripts, but they're worth recognising:

**"VPN connected" but no internet at all.** Restarting `systemd-networkd` (a
`netplan apply` does this) **flushes the policy routing rules nordvpnd
installed**. The tunnel interface stays up and `nordvpn status` still reports
Connected, but nothing routes into it, and the kill switch then correctly
blocks the leaked direct path - so you get zero connectivity. Check with
`ip rule show`: if the `not from all fwmark 0xe1f1 lookup 205` rule is missing,
that's it. Fix: `nordvpn disconnect && nordvpn connect`.

**Ping works, DNS works, but HTTPS hangs or pages half-load.** MTU blackhole,
and the most misleading failure of the lot - it looks like DNS filtering or a
dead VPN, but it's neither. NordLynx advertises MTU 1420 while the real path
MTU is ~1390, so mid-sized packets vanish with no "fragmentation needed" reply.
Small packets (ping, DNS) sail through while every TLS handshake dies, so the
VPN reports perfectly healthy. Raw TCP to port 443 connects; `curl` then hangs.

Confirm by probing: `ping -M do -s 1360 1.1.1.1` succeeds while `-s 1372` fails.

Note `nordvpn set` has no MTU option, and nordvpnd re-asserts 1420 *after* the
interface appears, so it beats any udev rule. Hence two defences, in
`04-nordvpn-setup.sh`:

- **MSS clamping** in nftables (fixed 1340, not `rt mtu` - that reads the bogus
  1420 and clamps to 1380, still too big). This is the load-bearing fix: it
  works the instant the tunnel reconnects and is immune to the MTU race. It
  lives in our own `vpn_gateway` table so Nord's reconnects don't drop it.
- **A 60s MTU timer**, since MSS clamping can't help UDP/QUIC (streaming).

Verify after a reconnect: MTU will read 1420 for up to a minute, but HTTPS
should already work - that's the clamp doing its job.

**The printer can't be discovered on the network.** `avahi-daemon` is missing.
cupsd is configured with `BrowseLocalProtocols dnssd` but depends on Avahi to
do the actual mDNS advertising - without it the printer is shared and works
fine by direct address (`ipp://<ip>:631/printers/<name>`), yet broadcasts
nothing, so it looks simply absent to every client. Check with
`ss -ulpn | grep 5353` (nothing listening = no advertising) and confirm the fix
with `avahi-browse -art | grep -i 'Internet Printer'`. Installing Avahi is also
what enables AirPrint (iOS/macOS) and Mopria (Android) discovery.

**Clients on the gateway port never get a DHCP lease.** Nord's kill-switch
firewall drops the requests before dnsmasq sees them - its input chain is
`policy drop` and only accepts source addresses in the private ranges, but a
DHCP client has no address yet and sends from `0.0.0.0`. The symptom is
baffling: `tcpdump -i <port> port 67` shows requests arriving every few
seconds while dnsmasq logs nothing at all. Fix: `nordvpn allowlist add port 67
protocol UDP` (done by `05-vpn-gateway.sh`).

**`apt` can't resolve hostnames while the VPN is up.** Nord's firewall drops
DNS to any LAN address on purpose (anti-leak), so the router stops resolving
for this box. Fix: point the system resolver at a public DNS directly, as
`04-nordvpn-setup.sh` does.

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
