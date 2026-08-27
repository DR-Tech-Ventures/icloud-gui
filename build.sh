#!/bin/bash
# Builds "iCloud GUI.app". No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iCloud GUI"
BUNDLE_ID="com.local.icloudgui"
CONFIG="${1:-release}"
APP="build/${APP_NAME}.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/iCloudGUI"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iCloudGUI"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>iCloudGUI</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local tool</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>iCloud GUI reads your Photos library so you can pick photos and download the originals to a folder on this Mac or a NAS.</string>
</dict>
</plist>
PLIST

# TCC keys the Photos permission to the bundle id *and* its code signature,
# so an unsigned bundle gets no prompt at all -- signing is required.
#
# DO NOT add --options runtime to the ad-hoc or local-identity paths below. Hardened
# runtime makes macOS require a real Team ID to establish provenance for
# privacy-sensitive access; neither an ad-hoc nor a self-signed certificate has one, so
# TCC skips the prompt and returns "denied" outright. Verified: with --options runtime
# the Photos status goes notDetermined -> denied with no dialog.
#
# The exception is a notarised release. Notarisation REQUIRES hardened runtime, and it
# works there because a Developer ID certificate carries a real Team ID. See RELEASING.md.
SIGN_KEYCHAIN="icloudgui-signing.keychain"
SIGN_IDENTITY="iCloud GUI Local Signing"

if security find-identity "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    # Preferred. The designated requirement then references the certificate rather
    # than the code hash, so the Photos grant survives a rebuild.
    echo "==> Signing (local identity)"
    security unlock-keychain -p icloudgui-local "$SIGN_KEYCHAIN" 2>/dev/null || true
    codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
             --identifier "$BUNDLE_ID" \
             "$APP" 2>&1 | sed 's/^/    /'
else
    # Fallback. Works, but macOS re-asks for Photos access after every rebuild.
    # Run ./setup-signing.sh once to stop that.
    echo "==> Signing (ad-hoc -- run ./setup-signing.sh to keep grants across rebuilds)"
    codesign --force --deep --sign - \
             --identifier "$BUNDLE_ID" \
             "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> Built $APP"
