#!/bin/bash
# Regenerates Resources/AppIcon.png and Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
swift tools/make-icon.swift Resources/AppIcon.png
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
