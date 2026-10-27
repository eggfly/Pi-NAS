#!/bin/bash
# Measure how fast this Mac can pull data from each NAS disk: one big file and a
# folder of small files, from the NVMe cache, the USB HDD and (optionally) a raw
# disk, plus a network-only baseline. Drops the Pi's page cache before every run
# so each number is a cold read from disk. Read-only on the NAS.
#
#   NAS=pi@nas.local bash scripts/mac/speedtest.sh
#
# Optional:
#   BIG=share/Mac-Downloads/x.img   big file, relative to each disk root (must exist on both)
#   SMALL=share/some/dir            small-file folder, relative to each disk root
#   SIZE_MB=1024                    how much of the big file to read
#   RAW_DEV=/dev/disk/by-id/...     also read SIZE_MB straight off this block device
#   SMB=/Volumes/Share              also read BIG/SMALL through this mounted SMB share
#                                   (paths are taken relative to share/, i.e. BIG minus "share/")
set -u
NAS="${NAS:?set NAS=user@host}"
BIG="${BIG:-share/Mac-Downloads/2026-04-21-raspios-trixie-arm64.img}"
SMALL="${SMALL:-share/Mac-Downloads/retro-games/cs16-client}"
SIZE_MB="${SIZE_MB:-1024}"
RAW_DEV="${RAW_DEV:-}"
SMB="${SMB:-}"
ROOTS="/srv/ssd /srv/hdd"
SSH="ssh -o BatchMode=yes -c aes128-gcm@openssh.com"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
# Evict the test data from the Pi's page cache without root: GNU dd with
# iflag=nocache count=0 drops the cached pages of that one file.
dropcache() { $SSH "$NAS" "for r in $ROOTS; do dd if=\$r/'$BIG' iflag=nocache count=0 status=none;
  find \$r/'$SMALL' -type f -exec dd if={} iflag=nocache count=0 status=none \\; ; done"; }
# report <label> <seconds> <bytes>
report() { perl -e 'printf "  %-30s %6.1fs  %6.1f MB/s  %5.0f Mbps\n", $ARGV[0], $ARGV[1], $ARGV[2]/$ARGV[1]/1e6, $ARGV[2]*8/$ARGV[1]/1e6' "$@"; }
# timed <label> <command...>: run once with a cold cache; stdout is counted as transferred bytes
timed() { local label="$1"; shift; dropcache; local t0 n; t0=$(now); n=$("$@" | wc -c); report "$label" "$(perl -e "print $(now) - $t0")" "$n"; }
# zero_streams <n>: n parallel SSH streams of SIZE_MB/n each, network only
zero_streams() { local n=$1 i t0; t0=$(now)
  for i in $(seq "$n"); do $SSH "$NAS" "head -c $((SIZE_MB / n))M /dev/zero" > /dev/null & done; wait
  report "network only, $n streams" "$(perl -e "print $(now) - $t0")" "$((SIZE_MB / n * n * 1048576))"; }

echo "== $(date '+%F %T')  $(scutil --get ComputerName 2>/dev/null) -> $NAS"
iface=$(route -n get "${NAS#*@}" 2>/dev/null | awk '/interface:/{print $2}')
echo "route: ${iface:-?}"
system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{c=1;next} c&&/PHY Mode|Channel|Transmit Rate|Signal/{gsub(/^ +/,"");print "wifi:  "$0} c&&/Other Local/{exit}'

$SSH "$NAS" "for r in $ROOTS; do test -f \$r/'$BIG' && test -d \$r/'$SMALL' || echo \"missing test data under \$r\"; done" | grep . && exit 1
small_bytes=$($SSH "$NAS" "du -sb /srv/hdd/'$SMALL' | cut -f1")
small_files=$($SSH "$NAS" "find /srv/hdd/'$SMALL' -type f | wc -l | tr -d ' '")

echo; echo "-- big file, ${SIZE_MB} MB over SSH"
timed "network only, 1 stream" $SSH "$NAS" "head -c ${SIZE_MB}M /dev/zero"
zero_streams 4
for r in $ROOTS; do timed "$r" $SSH "$NAS" "head -c ${SIZE_MB}M $r/'$BIG'"; done
if [ -n "$RAW_DEV" ]; then
  if $SSH "$NAS" "sudo -n true" 2>/dev/null; then
    timed "raw $(basename "$RAW_DEV" | cut -c1-26)" \
      $SSH "$NAS" "sudo -n dd if='$RAW_DEV' bs=1M count=$SIZE_MB iflag=direct status=none"
  else echo "  raw device skipped: sudo on the NAS needs a password"; fi
fi
echo "  Pi TCP congestion control: $($SSH "$NAS" cat /proc/sys/net/ipv4/tcp_congestion_control)"

echo; echo "-- $small_files small files ($((small_bytes / 1000000)) MB) over SSH"
for r in $ROOTS; do timed "tar stream  $r" $SSH "$NAS" "tar -C $r/'$SMALL' -cf - ."; done
for r in $ROOTS; do
  rm -rf "$TMP/rs"; dropcache; t0=$(now)
  rsync -rt -e "$SSH" "$NAS:$r/$SMALL/" "$TMP/rs/" >/dev/null 2>&1 || echo "  rsync from $r failed"
  report "rsync       $r" "$(perl -e "print $(now) - $t0")" "$small_bytes"
done

if [ -n "$SMB" ]; then
  echo; echo "-- through SMB ($SMB, mergerfs picks whichever disk has the file first)"
  timed "big file" dd if="$SMB/${BIG#share/}" bs=1m count="$SIZE_MB" status=none
  rm -rf "$TMP/smb"; dropcache; t0=$(now)
  cp -R "$SMB/${SMALL#share/}" "$TMP/smb"
  report "small files (cp -R)" "$(perl -e "print $(now) - $t0")" "$small_bytes"
fi
