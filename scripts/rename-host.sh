#!/usr/bin/env bash
# Rename the NAS host to match its Bonjour/SMB service name, so "NAS.local" resolves instantly.
# Usage: sudo bash scripts/rename-host.sh [name]   (default: nas)
# Samba advertises the Bonjour service as "NAS" (netbios name); macOS Finder then tries the
# hostname NAS.local first. If the real hostname differs, every connect waits ~5 s for that lookup to fail.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
NEW=${1:-nas}
OLD=$(hostname)
[[ $OLD == "$NEW" ]] && { echo "already $NEW"; exit 0; }
hostnamectl set-hostname "$NEW"
# keep sudo/local lookups working
if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW/" /etc/hosts; else echo -e "127.0.1.1\t$NEW" >> /etc/hosts; fi
systemctl restart avahi-daemon
systemctl restart smbd
command -v tailscale >/dev/null && tailscale set --hostname="$NEW" 2>/dev/null || true
echo "hostname: $OLD -> $(hostname); /etc/hosts: $(grep '^127.0.1.1' /etc/hosts)"
echo "RENAME_DONE  (now: smb://$NEW.local, ssh pi@$NEW.local)"
