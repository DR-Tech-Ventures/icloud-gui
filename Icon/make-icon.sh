#!/bin/bash
# Regenerates Icon/AppIcon.icns from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
echo "==> Icon/AppIcon.icns  ($(du -h AppIcon.icns | cut -f1))"

# The glyph layer for Icon/AppIcon.icon, the macOS 26 layered icon format. icon.json
# beside it is hand-written and committed -- it is small, and it is the one part of the
# icon a person might want to tweak (the gradient colour) without running anything.
# build.sh compiles the pair with actool, when Xcode is installed.
"$TMP/make-icon" --glyph AppIcon.icon/Assets
echo "==> Icon/AppIcon.icon  (open in Icon Composer to edit visually)"
