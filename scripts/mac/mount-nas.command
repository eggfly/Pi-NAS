#!/bin/bash
# Mount every NAS share (one per disk) in Finder. Double-click in Finder, or:
#   bash scripts/mac/mount-nas.command
# The first mount asks for the SMB password; tick "Remember this password in my keychain".
# Optional env: NAS (default pi@192.168.18.28), SHARES (default: the six disks).
NAS="${NAS:-pi@192.168.18.28}"
SHARES="${SHARES:-SSD Passport HDD1 HDD2 HDD3 HDD4}"

for s in $SHARES; do
  if [ -d "/Volumes/$s" ] && mount | grep -q " on /Volumes/$s "; then
    echo "already mounted: /Volumes/$s"
    continue
  fi
  open "smb://$NAS/$s"
  for _ in $(seq 60); do mount | grep -q " on /Volumes/$s " && break; sleep 1; done
done

echo
mount | grep -i smbfs | grep -E "/($(echo $SHARES | tr ' ' '|'))\b" || true
echo
df -h $(for s in $SHARES; do [ -d "/Volumes/$s" ] && echo "/Volumes/$s"; done) 2>/dev/null
