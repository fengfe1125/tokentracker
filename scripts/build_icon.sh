#!/usr/bin/env bash
# Explicit asset maintenance only. Normal App builds consume committed assets.
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tokentracker-icon.XXXXXX")"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/TokenTracker.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$d" "$d" assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_TMP/icon.icns"
cp "$ICON_TMP/icon.icns" assets/icon.icns
echo "Updated assets/icon.icns from the committed Figma PNG."
