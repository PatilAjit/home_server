#!/bin/bash
# Run on your WORKSTATION (not the NanoPi) - this is the chicken-and-egg step
# that gets you key-based access in the first place, so the other scripts in
# this repo can be run over ssh without a password prompt.
#
# Requires: ssh-keygen, and either `ssh-copy-id` (Linux/macOS) or PuTTY's
# `plink` (Windows, since OpenSSH's password auth can't be scripted headlessly
# without a tty). Needs the box's root password once - get it from your own
# password manager / SECRETS.local, never commit it.
set -euo pipefail

HOST="${HOMESERVER_HOST:?set HOMESERVER_HOST, e.g. 192.168.0.116}"
PASSWORD="${HOMESERVER_PASSWORD:?set HOMESERVER_PASSWORD (one-time use, for initial key push only)}"
KEY_PATH="${HOMESERVER_KEY:-$HOME/.ssh/id_ed25519}"

if [ ! -f "$KEY_PATH" ]; then
  ssh-keygen -t ed25519 -C "homeserver" -f "$KEY_PATH" -N ""
fi
PUBKEY=$(cat "${KEY_PATH}.pub")

if command -v ssh-copy-id >/dev/null 2>&1; then
  sshpass -p "$PASSWORD" ssh-copy-id -i "$KEY_PATH" "root@$HOST"
elif command -v plink >/dev/null 2>&1; then
  ssh-keygen -R "$HOST" 2>/dev/null || true
  printf "y\n" | plink -ssh -pw "$PASSWORD" "root@$HOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo KEY_INSTALLED"
else
  echo "Need either ssh-copy-id+sshpass, or PuTTY's plink, on the workstation." >&2
  exit 1
fi

ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$HOST" "echo Key login confirmed working."
