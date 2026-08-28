#!/bin/bash
# Builds "iCloud GUI.app". No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iCloud GUI"
# Overridable so release.sh can sign the same bundle under a different id.
BUNDLE_ID="${BUNDLE_ID:-com.drtechventures.icloudgui}"
CONFIG="${1:-release}"
APP="build/${APP_NAME}.app"

# macOS decides whether an app gets the Liquid Glass design by a linked-on-or-after
# check against the SDK version recorded in the binary's LC_BUILD_VERSION. SwiftPM has
# no notion of an SDK version separate from the deployment target, so it stamps both
# from Package.swift's .macOS(.v14) and the app is served the pre-Tahoe appearance
# however new the SDK it was actually compiled against. Stamping the real SDK version
# restores the split Xcode has by default: minos stays 14.0, sdk becomes the SDK in use.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="14.0"

echo "==> Compiling ($CONFIG, SDK $SDK_VERSION, deployment target $MIN_VERSION)"
swift build -c "$CONFIG" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$MIN_VERSION" -Xlinker "$SDK_VERSION"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/iCloudGUI"

# A previous instance launched from this bundle SURVIVES the rm -rf below -- macOS keeps
# the inode alive while a process holds it open -- and `open` then ACTIVATES that stale
# process instead of launching what was just built. Same pid, old binary, old arguments,
# running against a bundle whose resources no longer exist; it goes away later with no
# crash report, because being killed is not a crash. Verified: pid unchanged across a
# full rebuild followed by `open`.
#
# Targeted at this bundle's own path on purpose, so building in a checkout never quits
# a copy the user is running from /Applications.
RUNNING="$(pgrep -f "$PWD/$APP/Contents/MacOS/iCloudGUI" || true)"
if [ -n "$RUNNING" ]; then
    echo "==> Quitting the instance running from this bundle (pid $RUNNING)"
    # SIGTERM is safe here by design: downloads stream to .part files and are renamed
    # only on success, so an interrupted run leaves no truncated photo behind.
    kill $RUNNING 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$PWD/$APP/Contents/MacOS/iCloudGUI" >/dev/null 2>&1 || break
        sleep 0.3
    done
    pkill -9 -f "$PWD/$APP/Contents/MacOS/iCloudGUI" 2>/dev/null || true
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iCloudGUI"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>iCloudGUI</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>CFBundleVersion</key>           <string>3</string>
    <key>LSMinimumSystemVersion</key>    <string>${MIN_VERSION}</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 DR Tech Ventures LLC. Licensed under the Apache License 2.0.</string>
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
