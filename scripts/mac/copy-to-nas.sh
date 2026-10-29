#!/bin/bash
# Copy big folders/files from a Mac to the NAS over SSH with resumable rsync.
# Never deletes anything. Verify with verify-copy.sh before removing originals.
#
#   NAS=pi@nas.local bash scripts/mac/copy-to-nas.sh manifest.tsv
#
# manifest.tsv: one item per line, TAB-separated: <path relative to $HOME>  <NAS dest dir>
#   Movies/SomeFilm	/srv/passport/media/Movies
#   Downloads/musics	/srv/passport/media/Music
# Each source is copied *into* its dest dir (rsync without trailing slash).
# Re-run to resume: finished files are skipped, partial ones continue.
set -u
MANIFEST="${1:?usage: NAS=user@host $0 manifest.tsv}"
NAS="${NAS:?set NAS=user@host}"
SSH="ssh -o BatchMode=yes -c aes128-gcm@openssh.com"
W="${WORKDIR:-$HOME/nas-move}"
mkdir -p "$W"
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
cd ~ || exit 1

# Create all destination dirs in one SSH round trip (paths NUL-separated on stdin)
cut -f2 "$MANIFEST" | grep . | sort -u | tr '\n' '\0' | $SSH "$NAS" 'xargs -0 mkdir -p' ||
  { echo "cannot create destination dirs on $NAS"; exit 1; }

: > "$W/failed.txt"
while IFS=$'\t' read -r src dest; do
  [ -z "$src" ] && continue
  [ -e "$src" ] || { echo "missing: $src"; printf '%s\n' "$src" >> "$W/failed.txt"; continue; }
  echo "== $(date +%T) $src -> $dest"
  rsync -rt --partial -e "$SSH" "$src" "$NAS:$dest/" ||
    { echo "FAIL $src"; printf '%s\n' "$src" >> "$W/failed.txt"; }
done < "$MANIFEST"
echo "COPY_DONE failed=$(wc -l < "$W/failed.txt")"
