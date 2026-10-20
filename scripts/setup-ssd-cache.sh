#!/usr/bin/env bash
# Put an NVMe SSD in front of the NAS hard disk as an inclusive LRU cache (mergerfs + nas-tier).
# Run after setup-nas.sh, as root, from a clone of this repo:
#   sudo bash scripts/setup-ssd-cache.sh
# Optional env: SSD_DEV (default /dev/nvme0n1), MINFREE (default 50G).
#
# Result:
#   /srv/ssd  NVMe ext4 "nascache"        new files land here first; recently used files stay here
#   /srv/hdd  existing HDD ext4 "nasdata"  always holds a full copy; nothing on it is reformatted or deleted
#   /srv/nas  mergerfs pool = ssd + hdd    Samba serves this; Time Machine goes to /srv/hdd directly
#   nas-tier  nightly: copy SSD changes to the HDD (SSD copy kept), evict least-recently-used SSD copies
#             once the SSD passes 80% (only after a byte-compare with the HDD copy), promote hot HDD files.
#             Every 15 min: evict early if the SSD passes 80%.
# The first run formats the SSD (shows its contents and asks for YES first).
# Re-running is safe and also upgrades an older setup (nas-mover, noatime, no mergerfs caching).
set -euo pipefail

SSD_DEV=${SSD_DEV:-/dev/nvme0n1}
MINFREE=${MINFREE:-50G}
POOL=/srv/nas; HDD=/srv/hdd; SSD=/srv/ssd
HDD_LABEL=nasdata; SSD_LABEL=nascache
HERE="$(cd "$(dirname "$0")/.." && pwd)"
POOL_OPTS="category.create=ff,minfreespace=$MINFREE,moveonenospc=true,cache.files=partial,dropcacheonclose=true,cache.entry=5,cache.attr=5,cache.negative_entry=5,cache.readdir=true,inodecalc=path-hash,xattr=passthrough,fsname=nas,nofail,x-systemd.requires-mounts-for=$SSD,x-systemd.requires-mounts-for=$HDD"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -b $SSD_DEV ]] || { echo "no $SSD_DEV"; exit 1; }
blkid -L "$HDD_LABEL" >/dev/null || { echo "no '$HDD_LABEL' volume - run setup-nas.sh first"; exit 1; }
systemctl stop nvme-writetest 2>/dev/null || true

echo "==> Packages"
apt-get install -y mergerfs psmisc rsync parted python3 >/dev/null

echo "==> SSD"
if ! blkid -L "$SSD_LABEL" >/dev/null 2>&1; then
  if findmnt -no SOURCE / | grep -q "^$SSD_DEV"; then echo "$SSD_DEV holds / - refusing"; exit 1; fi
  if lsblk -no MOUNTPOINT "$SSD_DEV" | grep -q .; then echo "$SSD_DEV is mounted - refusing"; exit 1; fi
  echo "Current contents of $SSD_DEV:"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$SSD_DEV"
  wipefs -n "$SSD_DEV" || true
  for P in $(lsblk -lnpo NAME "$SSD_DEV" | tail -n +2); do
    if mount -o ro "$P" /mnt 2>/dev/null; then
      echo "--- $P top level:"; ls -la /mnt | head -30
      [[ -d /mnt/home ]] && { echo "--- $P /home:"; du -sh /mnt/home/* 2>/dev/null; }
      umount /mnt
    fi
  done
  read -rp "ERASE $SSD_DEV and format it as the cache SSD? Type YES: " OK
  [[ $OK == YES ]] || { echo "aborted"; exit 1; }
  wipefs -a "$SSD_DEV"
  parted -s "$SSD_DEV" mklabel gpt mkpart cache ext4 1MiB 100%
  partprobe "$SSD_DEV"; sleep 2
  PART=$(lsblk -lnpo NAME "$SSD_DEV" | sed -n 2p)
  mkfs.ext4 -F -L "$SSD_LABEL" -m 0 "$PART"     # mkfs discards (TRIMs) the whole partition
  sleep 2; umount "$PART" 2>/dev/null || true
fi
HDD_UUID=$(blkid -L "$HDD_LABEL" | xargs blkid -s UUID -o value)
SSD_UUID=$(blkid -L "$SSD_LABEL" | xargs blkid -s UUID -o value)

echo "==> Stop Samba and the old mover while the mounts change"
systemctl stop smbd
systemctl disable --now nas-mover.timer nas-mover-check.timer 2>/dev/null || true
# Whatever fails from here on, don't leave the NAS without Samba
trap 'echo "!! failed - restarting smbd"; systemctl start smbd' ERR

echo "==> Unmount the pool (or the bare HDD on a first run)"
if mountpoint -q "$POOL"; then
  if ! umount "$POOL"; then
    echo "!! $POOL is busy. Processes using it (cd out of it / close them, then re-run):"
    fuser -vm "$POOL" 2>&1 | sed 's/^/   /'
    false
  fi
fi
mkdir -p "$HDD" "$SSD"
for d in "$HDD" "$SSD" "$POOL"; do mountpoint -q "$d" || chattr +i "$d" 2>/dev/null || true; done

echo "==> fstab (tiers with relatime so client reads keep LRU order; pool with metadata caching)"
cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
sed -i -e "\#UUID=$HDD_UUID#d" -e "\#UUID=$SSD_UUID#d" -e "\#[[:space:]]$POOL[[:space:]]#d" /etc/fstab
cat >> /etc/fstab <<FSTAB
UUID=$HDD_UUID $HDD ext4 defaults,relatime,nofail,x-systemd.device-timeout=30 0 2
UUID=$SSD_UUID $SSD ext4 defaults,relatime,nofail 0 2
$SSD:$HDD $POOL fuse.mergerfs $POOL_OPTS 0 0
FSTAB
systemctl daemon-reload
for d in "$HDD" "$SSD"; do
  if mountpoint -q "$d"; then mount -o remount,relatime "$d"; else mount "$d"; fi
done
mount "$POOL"
for d in "$HDD" "$SSD" "$POOL"; do mountpoint -q "$d" || { echo "$d not mounted"; false; }; done

echo "==> Top-level dirs on the SSD (same owner/mode as on the HDD)"
for d in share media; do install -d -o root -g nas -m 2775 "$SSD/$d"; done

echo "==> Samba: Time Machine straight to the HDD; start after the pool is mounted"
sed -i "s#path = $POOL/timemachine/%U#path = $HDD/timemachine/%U#" /etc/samba/smb.conf
mkdir -p /etc/systemd/system/smbd.service.d
cat > /etc/systemd/system/smbd.service.d/after-pool.conf <<CONF
[Unit]
RequiresMountsFor=$POOL $HDD
CONF
testparm -s 2>/dev/null | grep -E "^\[|path =" || true
systemctl daemon-reload
systemctl start smbd
trap - ERR

echo "==> SMART: explicit device lines (Debian's DEVICESCAN line makes smartd ignore them)"
sed -i 's/^DEVICESCAN/#DEVICESCAN/' /etc/smartd.conf
grep -q "^/dev/nvme0 " /etc/smartd.conf || echo "/dev/nvme0 -d nvme -a -s (S/../.././02|L/../../7/03)" >> /etc/smartd.conf
# Older setup-nas.sh lines: the USB HDD needs -d removable (not yet enumerated at boot) and -n standby
sed -i -E '/^\/dev\/disk\/by-id\/usb-/{ /-d removable/! s/ -d sat / -d sat -d removable -n standby,10,q / }' /etc/smartd.conf
mkdir -p /etc/systemd/system/smartmontools.service.d
printf '[Unit]\nRequiresMountsFor=%s %s\n' "$HDD" "$SSD" > /etc/systemd/system/smartmontools.service.d/after-disks.conf
systemctl daemon-reload
systemctl restart smartmontools 2>/dev/null || systemctl restart smartd || true

echo "==> nas-tier + timers (replaces the old nas-mover)"
rm -f /etc/systemd/system/nas-mover.service /etc/systemd/system/nas-mover.timer \
      /etc/systemd/system/nas-mover-check.service /etc/systemd/system/nas-mover-check.timer /usr/local/sbin/nas-mover
install -m 755 "$HERE/scripts/nas-tier" /usr/local/sbin/nas-tier
cat > /etc/systemd/system/nas-tier.service <<UNIT
[Unit]
Description=Tier SSD <-> HDD: sync, LRU evict, promote
RequiresMountsFor=$SSD $HDD
[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/nas-tier all
UNIT
cat > /etc/systemd/system/nas-tier.timer <<UNIT
[Unit]
Description=Nightly SSD/HDD tiering
[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/nas-tier-evict.service <<UNIT
[Unit]
Description=Evict LRU SSD copies early if the SSD is filling up
RequiresMountsFor=$SSD $HDD
[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/nas-tier evict
UNIT
cat > /etc/systemd/system/nas-tier-evict.timer <<UNIT
[Unit]
Description=Check SSD fill level every 15 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now nas-tier.timer nas-tier-evict.timer

echo "==> Initial sync SSD -> HDD in the background (journalctl -u nas-tier-initial -f)"
systemctl reset-failed nas-tier-initial 2>/dev/null || true
systemd-run --unit=nas-tier-initial --property=Nice=10 --property=IOSchedulingClass=idle /usr/local/sbin/nas-tier sync

echo
df -h "$SSD" "$HDD" "$POOL"
for o in cache.entry cache.attr cache.negative_entry cache.readdir; do
  printf '%s=%s ' "$o" "$(getfattr -n "user.mergerfs.$o" --only-values "$POOL/.mergerfs" 2>/dev/null || echo '?')"
done; echo
echo "SSD_CACHE_DONE"
