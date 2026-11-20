#!/usr/bin/env bash
# Regenerates design/Fenrir.icns from design/fenrir-icon.svg (needs rsvg-convert and iconutil).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$(mktemp -d)/Fenrir.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$ROOT/design/fenrir-icon.svg" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) "$ROOT/design/fenrir-icon.svg" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/design/Fenrir.icns"
echo "wrote $ROOT/design/Fenrir.icns"
