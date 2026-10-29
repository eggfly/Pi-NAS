#!/usr/bin/env bash
# One mount and one Samba share per physical disk. No pooling, no caching, no data moved between disks.
# Run as root from a clone of this repo (setup-nas.sh runs it too):
#   sudo bash scripts/setup-disks.sh
# Optional env: DISKS (default below: "<ext4 label>:<share name> ..."), NAS_USER (default: the sudo user),
#               LAN_CIDR (default: eth0's subnet).
#
# Each disk is an ext4 volume found by its label and mounted at /srv/<label>; Samba shares it as <share name>.
# A label that doesn't exist yet: the script lists the disks and asks which one to FORMAT for it
# (Enter skips; that disk then gets no mount and no share).
#
# Also migrates the old mergerfs + nas-tier cache setup (setup-ssd-cache.sh): byte-compares every file on the
# SSD with the HDD, removes the pool and timers, renames nasdata -> passport and nascache -> ssd, and offers
# to delete the SSD's cache copies and the old Time Machine folder (each asks for YES).
# Re-running is safe.
set -euo pipefail

DISKS=${DISKS:-"ssd:SSD passport:Passport hdd1:HDD1 hdd2:HDD2 hdd3:HDD3 hdd4:HDD4"}
RENAMES="nasdata:passport nascache:ssd"          # old label -> new label
NAS_USER="${NAS_USER:-${SUDO_USER:-pi}}"
OLD_POOL=/srv/nas; OLD_HDD=/srv/hdd; OLD_SSD=/srv/ssd
HERE="$(cd "$(dirname "$0")/.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
LAN_CIDR="${LAN_CIDR:-$(ip -4 route show dev eth0 scope link proto kernel 2>/dev/null | awk 'NR==1{print $1}')}"
[[ -n $LAN_CIDR ]] || { echo "could not detect eth0 subnet; set LAN_CIDR=192.168.x.0/24"; exit 1; }
getent group nas >/dev/null || groupadd nas
usermod -aG nas "$NAS_USER"
apt-get install -y samba rsync parted psmisc smartmontools hd-idle >/dev/null

ask_yes() { local a; read -rp "$1 Type YES: " a; [[ $a == YES ]]; }
unmount() {   # unmount if mounted; show who holds it if busy
  mountpoint -q "$1" || return 0
  umount "$1" && return 0
  echo "!! $1 is busy (cd out of it / close these, then re-run):"; fuser -vm "$1" 2>&1 | sed 's/^/   /'; return 1
}

systemctl stop smbd
trap 'echo "!! failed - restarting smbd"; systemctl start smbd' ERR

if mountpoint -q "$OLD_POOL" || [[ -e /etc/systemd/system/nas-tier.timer ]]; then
  echo "==> Old cache setup found (mergerfs $OLD_POOL + nas-tier)"
  systemctl disable --now nas-tier.timer nas-tier-evict.timer 2>/dev/null || true
  unmount "$OLD_POOL"
  rm -f /etc/systemd/system/nas-tier{,-evict}.{service,timer} /etc/systemd/system/smbd.service.d/after-pool.conf
  if mountpoint -q "$OLD_SSD" && mountpoint -q "$OLD_HDD" && [[ -d $OLD_SSD/share || -d $OLD_SSD/media ]]; then
    [[ -x /usr/local/sbin/nas-tier ]] && /usr/local/sbin/nas-tier sync
    echo "   Byte-comparing every SSD file with the HDD (reads both in full; can take an hour)..."
    DIFF=$(rsync -rlnci --exclude=/lost+found "$OLD_SSD/" "$OLD_HDD/" | grep -v '^\.d' || true)
    if [[ -n $DIFF ]]; then
      echo "!! These SSD files are missing or different on the HDD - copy them over, then re-run:"
      echo "$DIFF" | head -50 | sed 's/^/   /'
      false
    fi
    echo "   OK: every SSD file is also on the HDD"
    du -sh "$OLD_SSD"/share "$OLD_SSD"/media 2>/dev/null | sed 's/^/   /'
    if ask_yes "   Delete these cache copies from the SSD?"; then rm -rf "$OLD_SSD"/share "$OLD_SSD"/media; fi
  fi
  rm -f /usr/local/sbin/nas-tier
fi

echo "==> Time Machine is no longer served"
for TM in "$OLD_HDD/timemachine" /srv/passport/timemachine; do
  [[ -d $TM ]] || continue
  du -sh "$TM"/*/* 2>/dev/null | sed 's/^/   /'
  if ask_yes "   Delete $TM and every backup in it?"; then rm -rf "$TM"; else echo "   kept $TM"; fi
done

echo "==> Labels"
for R in $RENAMES; do
  OLD=${R%%:*} NEW=${R#*:}
  if DEV=$(blkid -L "$OLD" 2>/dev/null) && ! blkid -L "$NEW" >/dev/null 2>&1; then
    e2label "$DEV" "$NEW"; echo "   $DEV: $OLD -> $NEW"
  fi
done
udevadm settle

echo "==> Format disks that don't have their label yet"
NAS_LABELS=$(for D in $DISKS $RENAMES; do echo "${D%%:*}"; done | paste -sd'|')
for D in $DISKS; do
  L=${D%%:*}
  blkid -L "$L" >/dev/null 2>&1 && continue
  echo "No volume labelled '$L'. Disks:"
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS
  read -rp "Disk to FORMAT as '$L' (e.g. sdb; Enter to skip): " DISK
  [[ -n $DISK ]] || { echo "   skipped $L"; continue; }
  DEV=/dev/$DISK
  [[ -b $DEV && $(lsblk -dno TYPE "$DEV") == disk ]] || { echo "no such disk $DEV"; false; }
  if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then echo "$DEV is mounted - refusing"; false; fi
  if lsblk -no LABEL "$DEV" | grep -qxE "$NAS_LABELS"; then echo "$DEV holds a NAS volume - refusing"; false; fi
  wipefs -n "$DEV" || true
  ask_yes "ALL DATA on $DEV ($(lsblk -dno SIZE,MODEL,SERIAL "$DEV" | xargs)) will be erased." || { echo "aborted"; false; }
  wipefs -a "$DEV"
  parted -s "$DEV" mklabel gpt mkpart "$L" ext4 1MiB 100%
  partprobe "$DEV"; udevadm settle
  PART=$(lsblk -lnpo NAME "$DEV" | sed -n 2p)
  mkfs.ext4 -F -L "$L" -m 0 -T largefile "$PART"
  udevadm settle
done

PRESENT=()
for D in $DISKS; do blkid -L "${D%%:*}" >/dev/null 2>&1 && PRESENT+=("$D"); done
MOUNTS=(); for D in "${PRESENT[@]}"; do MOUNTS+=("/srv/${D%%:*}"); done

echo "==> fstab (by label, so a name stays with its disk whatever sdX it gets)"
cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
awk -v drop="$OLD_POOL $OLD_HDD ${MOUNTS[*]}" '
  BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) skip[d[i]] = 1 }
  !($2 in skip)' /etc/fstab > /etc/fstab.new
for M in "${MOUNTS[@]}"; do
  echo "LABEL=${M#/srv/} $M ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab.new
done
mv /etc/fstab.new /etc/fstab
systemctl daemon-reload

echo "==> Mounts"
for M in "$OLD_HDD" "$OLD_POOL"; do
  unmount "$M"
  [[ -d $M ]] && { chattr -i "$M" 2>/dev/null || true; rmdir "$M" || echo "   $M not empty - left in place"; }
done
for M in "${MOUNTS[@]}"; do
  if ! mountpoint -q "$M"; then
    mkdir -p "$M"
    chattr +i "$M" 2>/dev/null || true   # empty + immutable: a missing disk can't fill the eMMC
    mount "$M"
  fi
  chown root:nas "$M"; chmod 2775 "$M"
done

echo "==> Samba: one share per disk"
[[ -f /etc/samba/smb.conf.orig ]] || cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
{
  sed "s#@LAN_CIDR@#$LAN_CIDR#" "$HERE/configs/smb.conf"
  echo
  echo "# Shares below are generated by scripts/setup-disks.sh - one per physical disk"
  for D in "${PRESENT[@]}"; do
    cat <<CONF

[${D#*:}]
   path = /srv/${D%%:*}
   valid users = @nas
   read only = no
   browseable = yes
   create mask = 0664
   directory mask = 2775
   force group = nas
   veto files = /lost+found/
CONF
  done
} > /etc/samba/smb.conf.new
chmod 644 /etc/samba/smb.conf.new
testparm -s /etc/samba/smb.conf.new >/dev/null
mv /etc/samba/smb.conf.new /etc/samba/smb.conf
testparm -s 2>/dev/null | grep -E '^\[|path =' | sed 's/^/   /'
systemctl daemon-reload
systemctl start smbd
trap - ERR

echo "==> Spin-down (hd-idle, 20 min) and SMART for every USB disk"
IDLE="" SMART_IDS=()
for M in "${MOUNTS[@]}"; do
  PK=$(lsblk -no PKNAME "$(blkid -L "${M#/srv/}")")
  ID=$(find /dev/disk/by-id -lname "*/$PK" -name 'usb-*' | head -1)
  [[ -n $ID ]] || continue        # NVMe: nothing to spin down; smartd line below
  IDLE+=" -a $ID -i 1200"
  SMART_IDS+=("$ID")
done
# -i 0: leave unnamed disks alone. -s 1: re-resolve the by-id links if a disk comes back as another sdX.
printf 'START_HD_IDLE=true\nHD_IDLE_OPTS="-s 1 -i 0%s"\n' "$IDLE" > /etc/default/hd-idle
systemctl enable hd-idle >/dev/null 2>&1 || true
systemctl restart hd-idle || true
# Debian ships a DEVICESCAN line that makes smartd ignore explicit device lines
sed -i 's/^DEVICESCAN/#DEVICESCAN/' /etc/smartd.conf
# -d removable: the disk may not be enumerated yet when smartd starts. -n standby: don't wake it for checks.
for ID in "${SMART_IDS[@]}"; do
  grep -q "^$ID " /etc/smartd.conf || \
    echo "$ID -d sat -d removable -n standby,10,q -a -o on -S on -s (S/../.././02|L/../01/./03)" >> /etc/smartd.conf
done
if [[ -e /dev/nvme0 ]] && ! grep -q "^/dev/nvme0 " /etc/smartd.conf; then
  echo "/dev/nvme0 -d nvme -a -s (S/../.././02|L/../../7/03)" >> /etc/smartd.conf
fi
# Start after the disk mounts, but don't require them: one missing disk must not stop smartd
UNITS=$(for M in "${MOUNTS[@]}"; do systemd-escape -p --suffix=mount "$M"; done | paste -sd' ')
mkdir -p /etc/systemd/system/smartmontools.service.d
printf '[Unit]\nWants=%s\nAfter=%s\n' "$UNITS" "$UNITS" > /etc/systemd/system/smartmontools.service.d/after-disks.conf
systemctl daemon-reload
systemctl restart smartmontools 2>/dev/null || systemctl restart smartd || true

echo
df -h "${MOUNTS[@]}"
echo "Finder: smb://$(hostname).local -> $(for D in "${PRESENT[@]}"; do printf '%s ' "${D#*:}"; done)"
echo "DISKS_DONE"
