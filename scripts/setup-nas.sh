#!/usr/bin/env bash
# Pi-NAS setup: Raspberry Pi CM5 + USB 3 / NVMe disks -> SMB3 NAS for macOS, one share per disk.
# Run on Raspberry Pi OS (Debian 13 "trixie") as root, from a clone of this repo:
#   sudo bash scripts/setup-nas.sh
# Optional env: NAS_USER (default: the sudo user), LAN_CIDR (default: eth0's subnet).
# Disks are set up by scripts/setup-disks.sh (run at the end): it asks which disk to format for each
# label that doesn't exist yet -> ALL DATA ON THAT DISK IS ERASED. Existing labelled volumes are reused.
set -euo pipefail

NAS_USER="${NAS_USER:-${SUDO_USER:-pi}}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
id "$NAS_USER" >/dev/null 2>&1 || { echo "user $NAS_USER does not exist"; exit 1; }

LAN_CIDR="${LAN_CIDR:-$(ip -4 route show dev eth0 scope link proto kernel 2>/dev/null | awk 'NR==1{print $1}')}"
[[ -n $LAN_CIDR ]] || { echo "could not detect eth0 subnet; set LAN_CIDR=192.168.x.0/24"; exit 1; }
echo "NAS user: $NAS_USER   LAN: $LAN_CIDR"

echo "==> Packages"
apt-get update
apt-get install -y samba avahi-daemon smartmontools hd-idle cockpit rsync ufw unattended-upgrades parted

echo "==> Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
# Log in later with `sudo tailscale up`

echo "==> USB current limit"
# The firmware caps USB at 600mA unless it sees a 5V/5A supply; a bus-powered 2.5" HDD needs more.
CFG=/boot/firmware/config.txt
grep -q '^usb_max_current_enable=1' "$CFG" || echo 'usb_max_current_enable=1' >> "$CFG"

echo "==> TCP: BBR + fq"
# Wi-Fi clients lose ~0.1% of packets on the downlink; cubic then caps one TCP
# connection (one SMB session) at ~10 MB/s. BBR doesn't back off on random loss.
echo tcp_bbr > /etc/modules-load.d/bbr.conf
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-bbr.conf
modprobe tcp_bbr
sysctl -q -p /etc/sysctl.d/90-bbr.conf
tc qdisc replace dev eth0 root fq

echo "==> Samba (smb.conf and the shares are written by setup-disks.sh)"
# Start smbd after the network and tailscaled are up (smbd listens on all addresses; see smb.conf)
mkdir -p /etc/systemd/system/smbd.service.d
cat > /etc/systemd/system/smbd.service.d/after-tailscale.conf <<CONF
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
CONF
systemctl daemon-reload
systemctl enable smbd avahi-daemon
systemctl start avahi-daemon
systemctl disable --now nmbd 2>/dev/null || true   # NetBIOS is not needed for macOS

echo "==> Disks, shares, spin-down, SMART"
NAS_USER="$NAS_USER" LAN_CIDR="$LAN_CIDR" bash "$HERE/scripts/setup-disks.sh"

echo "==> Firewall: LAN + Tailscale only (22 ssh, 445 smb, 5900 vnc/wayvnc if enabled, 9090 cockpit)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
for SRC in "$LAN_CIDR" 100.64.0.0/10 fd7a:115c:a1e0::/48; do
  for PORT in 22 445 5900 9090; do ufw allow from "$SRC" to any port "$PORT" proto tcp; done
done
ufw allow 5353/udp      # mDNS (Bonjour discovery on the LAN)
ufw allow 41641/udp     # Tailscale direct connections (WireGuard)
# REJECT (not silent DROP) everything else on these ports. Bonjour also advertises the
# NAS's public IPv6 address and macOS tries it first; an instant RST makes it fall back
# to IPv4 at once instead of stalling ~5 s on every SMB connect.
for PORT in 22 445 5900 9090; do ufw reject proto tcp to any port "$PORT"; done
ufw --force enable

echo "==> SSH: keys only"
if [[ -s /home/$NAS_USER/.ssh/authorized_keys ]]; then
  cat > /etc/ssh/sshd_config.d/10-nas-hardening.conf <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
  systemctl reload ssh
else
  echo "   (skipped: no authorized_keys for $NAS_USER - add a key first, then re-run)"
fi

echo "==> Automatic security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo
echo "Done. Next:"
echo "  sudo smbpasswd -a $NAS_USER         # SMB password (used by Finder)"
echo "  sudo tailscale up                    # remote access; disable key expiry for this node"
echo "  Finder: smb://$(hostname).local      (one share per disk)"
echo "  Cockpit: https://$(hostname).local:9090"
echo "  Reboot once so usb_max_current_enable takes effect."
