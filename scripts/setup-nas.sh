#!/usr/bin/env bash
# Pi-NAS setup: Raspberry Pi CM5 + one USB 3 hard disk -> SMB3 / Time Machine NAS for macOS.
# Run on Raspberry Pi OS (Debian 13 "trixie") as root, from a clone of this repo:
#   sudo bash scripts/setup-nas.sh
# Optional env: NAS_USER (default: the sudo user), LAN_CIDR (default: eth0's subnet).
# The data disk is formatted as ext4 the first time -> ALL DATA ON IT IS ERASED.
# Re-running is safe: an existing "nasdata" ext4 volume is reused, not reformatted.
set -euo pipefail

NAS_USER="${NAS_USER:-${SUDO_USER:-pi}}"
MOUNT=/srv/nas
LABEL=nasdata
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

echo "==> Data disk"
if ! blkid -L "$LABEL" >/dev/null 2>&1; then
  lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT
  read -rp "Disk to FORMAT as ext4 (e.g. sda): " DISK
  DEV="/dev/$DISK"
  [[ -b $DEV ]] || { echo "no such disk $DEV"; exit 1; }
  # Refuse anything mounted outside the desktop automount area (system disk, other data)
  if lsblk -no MOUNTPOINT "$DEV" | grep -vE '^$|^/media/' | grep -q .; then
    echo "$DEV has partitions mounted outside /media — refusing"; exit 1
  fi
  read -rp "ALL DATA on $DEV will be erased. Type YES to continue: " OK
  [[ $OK == YES ]] || { echo "aborted"; exit 1; }
  # Desktop automount (/media/<user>/...) keeps the partitions busy
  for P in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do umount "$P" 2>/dev/null || true; done
  wipefs -a "$DEV"
  parted -s "$DEV" mklabel gpt mkpart nas ext4 1MiB 100%
  partprobe "$DEV"; sleep 2
  PART=$(lsblk -lnpo NAME "$DEV" | sed -n 2p)
  mkfs.ext4 -F -L "$LABEL" -m 0 -T largefile "$PART"
  sleep 2; umount "$PART" 2>/dev/null || true   # in case the desktop automounted it
fi
UUID=$(blkid -L "$LABEL" | xargs blkid -s UUID -o value)

mkdir -p "$MOUNT"
if ! mountpoint -q "$MOUNT"; then
  # Immutable empty mount point: if the disk is missing, nothing gets written to the SD/eMMC
  chattr +i "$MOUNT" || true
fi
grep -q "$UUID" /etc/fstab || \
  echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab
systemctl daemon-reload
mount "$MOUNT" 2>/dev/null || true
mountpoint -q "$MOUNT" || { echo "disk not mounted at $MOUNT"; exit 1; }

echo "==> Users & directories"
getent group nas >/dev/null || groupadd nas
usermod -aG nas "$NAS_USER"
mkdir -p "$MOUNT"/{share,media,timemachine/"$NAS_USER"}
chown root:nas "$MOUNT"/share "$MOUNT"/media
chmod 2775 "$MOUNT"/share "$MOUNT"/media
chown "$NAS_USER":nas "$MOUNT"/timemachine/"$NAS_USER"
chmod 0700 "$MOUNT"/timemachine/"$NAS_USER"
chmod 0755 "$MOUNT"/timemachine

echo "==> Samba"
[[ -f /etc/samba/smb.conf.orig ]] || cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
sed "s#@LAN_CIDR@#$LAN_CIDR#" "$HERE/configs/smb.conf" > /etc/samba/smb.conf
chmod 644 /etc/samba/smb.conf
testparm -s >/dev/null
# Start smbd after the network and tailscaled are up (smbd listens on all addresses; see smb.conf)
mkdir -p /etc/systemd/system/smbd.service.d
cat > /etc/systemd/system/smbd.service.d/after-tailscale.conf <<CONF
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
CONF
systemctl daemon-reload
systemctl enable --now smbd avahi-daemon
systemctl restart smbd
systemctl disable --now nmbd 2>/dev/null || true   # NetBIOS is not needed for macOS

# Whole-disk name (hd-idle / smartd act on the disk, not the partition)
PK=$(lsblk -no PKNAME "$(blkid -L "$LABEL")")
DISK_ID=$(find /dev/disk/by-id -lname "*/$PK" | grep -m1 usb- || echo "/dev/$PK")

echo "==> Spin down the disk after 20 min idle ($DISK_ID)"
cat > /etc/default/hd-idle <<CONF
START_HD_IDLE=true
HD_IDLE_OPTS="-i 0 -a $PK -i 1200"
CONF
systemctl enable --now hd-idle || true

echo "==> SMART monitoring"
# Debian ships a DEVICESCAN line that makes smartd ignore explicit device lines
sed -i 's/^DEVICESCAN/#DEVICESCAN/' /etc/smartd.conf
# -d removable: the USB disk may not be enumerated yet when smartd starts at boot (else smartd exits)
# -n standby,10,q: routine checks don't wake a spun-down disk. Short test daily, long test monthly.
grep -q "^$DISK_ID" /etc/smartd.conf || \
  echo "$DISK_ID -d sat -d removable -n standby,10,q -a -o on -S on -s (S/../.././02|L/../01/./03)" >> /etc/smartd.conf
mkdir -p /etc/systemd/system/smartmontools.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT" > /etc/systemd/system/smartmontools.service.d/after-disks.conf
systemctl daemon-reload
systemctl enable --now smartmontools 2>/dev/null || systemctl restart smartd || true

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
# to IPv4 at once instead of stalling ~5 s on every SMB / Time Machine connect.
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
echo "  sudo smbpasswd -a $NAS_USER         # SMB password (used by Finder / Time Machine)"
echo "  sudo tailscale up                    # remote access; disable key expiry for this node"
echo "  Finder: smb://$(hostname).local      Time Machine: 'TimeMachine' on this NAS"
echo "  Cockpit: https://$(hostname).local:9090"
echo "  Reboot once so usb_max_current_enable takes effect."
