#!/bin/bash
# Regenerates Icon/AppIcon.icns from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
echo "==> Icon/AppIcon.icns  ($(du -h AppIcon.icns | cut -f1))"
