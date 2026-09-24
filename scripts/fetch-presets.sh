#!/bin/bash
# Fetch a curated MilkDrop .milk preset pack into vendor/presets.
# Default source: the Fedora libprojectM presets if present (638 .milk files),
# else download the projectM "cream of the crop" pack (curated subset).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/presets"

if [ -d "$DEST" ] && [ -n "$(ls "$DEST"/*.milk 2>/dev/null | head -1)" ]; then
    echo "presets already present at vendor/presets"
    exit 0
fi
mkdir -p "$DEST"

SYS="/usr/share/projectM/presets/presets_milkdrop"
if [ -d "$SYS" ]; then
    cp "$SYS"/*.milk "$DEST"/
    echo "copied $(ls "$DEST" | wc -l) presets from $SYS"
    exit 0
fi

echo "system presets not found; downloading cream-of-the-crop (~large)"
TMP="$(mktemp -d)"
git clone --depth 1 https://github.com/projectM-visualizer/presets-cream-of-the-crop.git "$TMP/cotc"
# NB: no `find | head` — under pipefail, head closing the pipe SIGPIPEs find
# and kills the script (bit CI, where this download branch actually runs)
# budget-capped: smallest-first up to ~6MB / 800 presets (the raw slice of
# the repo came out at 13.6MB — fat presets add little and bloat the package)
mapfile -t files < <(find "$TMP/cotc" -name "*.milk" -printf "%s\t%p\n" | sort -n | cut -f2)
budget=$((6 * 1024 * 1024)); total=0; count=0
for f in "${files[@]}"; do
    sz=$(stat -c%s "$f")
    (( total + sz > budget || count >= 800 )) && break
    cp "$f" "$DEST"/; total=$((total + sz)); count=$((count + 1))
done
rm -rf "$TMP"
echo "downloaded $(ls "$DEST" | wc -l) presets"
