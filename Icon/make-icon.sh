#!/bin/bash
# Regenerates Icon/AppIcon.icns from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
echo "==> Icon/AppIcon.icns  ($(du -h AppIcon.icns | cut -f1))"

# Source layers for the macOS 26 layered icon format. Icon Composer has no command
# line, so turning these into AppIcon.icon is a manual step -- see CONTRIBUTING.md.
# The .icns above stays the shipped icon until that file exists, and remains the icon
# macOS 14-25 uses either way.
"$TMP/make-icon" --layers Layers
echo "==> Icon/Layers/  (drag into Icon Composer)"
