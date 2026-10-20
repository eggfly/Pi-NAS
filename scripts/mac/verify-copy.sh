#!/bin/bash
# Verify every file from copy-to-nas.sh's manifest exists on the NAS with the same SHA-256.
#
#   NAS=pi@nas.local bash scripts/mac/verify-copy.sh manifest.tsv
#
# Output in $WORKDIR (default ~/nas-move):
#   verified.txt  sources whose every file matched (safe to move to the Trash)
#   mismatch.txt  "<sha>  <nas path>" lines that were missing or different on the NAS
set -u
MANIFEST="${1:?usage: NAS=user@host $0 manifest.tsv}"
NAS="${NAS:?set NAS=user@host}"
SSH="ssh -o BatchMode=yes -c aes128-gcm@openssh.com"
W="${WORKDIR:-$HOME/nas-move}"
mkdir -p "$W"
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
cd ~ || exit 1
: > "$W/mac.sha"; : > "$W/verified.txt"; : > "$W/mismatch.txt"; : > "$W/nas-paths.txt"

# Mac side: hash each source; rewrite paths to their location on the NAS
while IFS=$'\t' read -r src dest; do
  [ -z "$src" ] && continue
  printf '%s\n' "$dest/$(basename "$src")" >> "$W/nas-paths.txt"
  ( cd "$(dirname "$src")" && find "$(basename "$src")" -type f ! -name .DS_Store -print0 \
      | xargs -0 shasum -a 256 ) | sed "s#^\([0-9a-f]*\)  #\1  $dest/#" >> "$W/mac.sha"
done < "$MANIFEST"
echo "mac files: $(wc -l < "$W/mac.sha")"

# NAS side: hash exactly the copied trees (paths sent NUL-separated on stdin).
# One file at a time: parallel hashing makes a hard disk seek between files (measured 45 vs 119 MB/s).
tr '\n' '\0' < "$W/nas-paths.txt" |
  $SSH "$NAS" 'xargs -0 -I{} find {} -type f ! -name .DS_Store -print0 | xargs -0 sha256sum' > "$W/nas.sha"
echo "nas files: $(wc -l < "$W/nas.sha")"

# Every Mac line must appear verbatim (hash + path) on the NAS
sort -u "$W/nas.sha" > "$W/nas.sorted"
sort -u "$W/mac.sha" | comm -23 - "$W/nas.sorted" > "$W/mismatch.txt"
echo "missing or different: $(wc -l < "$W/mismatch.txt")"

# A source is verified only if none of its files are listed in mismatch.txt
while IFS=$'\t' read -r src dest; do
  [ -z "$src" ] && continue
  p="$dest/$(basename "$src")"
  if ! cut -c67- "$W/mismatch.txt" | grep -qxF -e "$p" && ! cut -c67- "$W/mismatch.txt" | grep -qF -e "$p/"; then
    printf '%s\n' "$src" >> "$W/verified.txt"
  fi
done < "$MANIFEST"
echo "VERIFY_DONE verified=$(wc -l < "$W/verified.txt")/$(grep -c . "$MANIFEST")"
