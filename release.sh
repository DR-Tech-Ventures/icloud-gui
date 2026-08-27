#!/bin/bash
# Signs, notarises and staples a distributable build.
#
# One-time setup is described in RELEASING.md. In short you need:
#   1. A paid Apple Developer Program membership
#   2. A "Developer ID Application" certificate in your keychain
#   3. A stored notarytool profile:
#        xcrun notarytool store-credentials icloudgui-notary \
#              --apple-id you@example.com --team-id DJ2RANBKU3
#      (that prompts for an app-specific password from appleid.apple.com --
#       never your real Apple ID password)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iCloud GUI"
BUNDLE_ID="${BUNDLE_ID:-com.drtechventures.icloudgui}"
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
No "Developer ID Application" certificate found in your keychains.

This project signs as DR Tech Ventures LLC (Team ID DJ2RANBKU3). An
"Apple Development" certificate is NOT sufficient -- it cannot notarise.

If a Developer ID certificate already exists on another Mac, export it there as a
.p12 (Keychain Access -> right-click the certificate -> Export) and double-click it
here. Apple caps how many Developer ID certificates a team may hold, so reuse beats
creating another.

Otherwise create one -- Account Holder or Admin on the team only:
  Xcode -> Settings -> Accounts -> DR Tech Ventures LLC
        -> Manage Certificates -> + -> Developer ID Application

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
        --apple-id "you@example.com" --team-id "DJ2RANBKU3"

MSG
    exit 1
fi

# --- Build -----------------------------------------------------------------
echo "==> Building"
rm -f "$SUBMIT_ZIP" "$DIST_ZIP"
# build.sh owns bundle assembly and the Info.plist, so the two cannot drift. It also
# signs with the local identity; the Developer ID signature below replaces that.
BUNDLE_ID="$BUNDLE_ID" ./build.sh release

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
