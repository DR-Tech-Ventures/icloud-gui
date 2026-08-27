#!/bin/bash
# Signs, notarises and staples a distributable build.
#
# One-time setup is described in RELEASING.md. In short you need:
#   1. A paid Apple Developer Program membership
#   2. A "Developer ID Application" certificate in your keychain
#   3. A stored notarytool profile:
#        xcrun notarytool store-credentials icloudgui-notary \
#              --apple-id you@example.com --team-id TEAMID
#      (that prompts for an app-specific password from appleid.apple.com --
#       never your real Apple ID password)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iCloud GUI"
BUNDLE_ID="${BUNDLE_ID:-com.local.icloudgui}"
PROFILE="${NOTARY_PROFILE:-icloudgui-notary}"
APP="build/${APP_NAME}.app"
SUBMIT_ZIP="build/submit.zip"
DIST_ZIP="build/${APP_NAME// /-}.zip"

# --- Preflight -------------------------------------------------------------
IDENTITY="$(security find-identity -v -p codesigning \
            | grep "Developer ID Application" \
            | head -1 | sed -E 's/.*"(.*)"/\1/')" || true

if [ -z "${IDENTITY:-}" ]; then
    cat >&2 <<'MSG'
No "Developer ID Application" certificate found.

This needs a PAID Apple Developer Program membership ($99/year). A free account
gets "Apple Development" certificates, which cannot notarise.

To create one:
  Xcode -> Settings -> Accounts -> select your team -> Manage Certificates
        -> + -> Developer ID Application

Then run this script again. See RELEASING.md.
MSG
    exit 1
fi
echo "==> Signing identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG

No stored notarytool profile called "$PROFILE".

Create one (it will prompt for an app-specific password -- generate that at
appleid.apple.com under Sign-In and Security, NOT your real Apple ID password):

  xcrun notarytool store-credentials "$PROFILE" \\
        --apple-id "you@example.com" --team-id "YOURTEAMID"

MSG
    exit 1
fi

if [ "$BUNDLE_ID" = "com.local.icloudgui" ]; then
    echo "!!  Bundle id is still com.local.icloudgui." >&2
    echo "!!  Set BUNDLE_ID to a reverse-DNS identifier you control before publishing." >&2
fi

# --- Build -----------------------------------------------------------------
echo "==> Building"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/iCloudGUI"

rm -rf "$APP" "$SUBMIT_ZIP" "$DIST_ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iCloudGUI"
# Reuse the Info.plist that build.sh writes, so the two cannot drift.
BUNDLE_ID="$BUNDLE_ID" ./build.sh release >/dev/null

# --- Sign ------------------------------------------------------------------
# --options runtime IS correct here, unlike in build.sh's local signing paths:
# notarisation requires hardened runtime, and a Developer ID certificate carries the
# real Team ID that TCC wants before it will show the Photos prompt.
echo "==> Signing (hardened runtime)"
codesign --force --deep --timestamp --options runtime \
         --entitlements release.entitlements \
         --sign "$IDENTITY" \
         --identifier "$BUNDLE_ID" \
         "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarise --------------------------------------------------------------
echo "==> Submitting to Apple (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

# --- Staple ----------------------------------------------------------------
# The ticket is stapled into the .app, then the stapled app is zipped for release.
# You cannot staple a zip, so the order matters.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# --- Verify as a downloader would see it -----------------------------------
echo "==> Gatekeeper assessment"
spctl -a -vvv "$APP"

ditto -c -k --keepParent "$APP" "$DIST_ZIP"
rm -f "$SUBMIT_ZIP"
echo
echo "==> Ready to publish: $DIST_ZIP"
echo "    Test the Photos prompt on a clean user account before releasing."
