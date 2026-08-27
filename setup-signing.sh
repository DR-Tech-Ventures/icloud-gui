#!/bin/bash
# Creates a local self-signed code-signing identity, once.
#
# Why: an ad-hoc signature has no stable identity, so macOS ties the Photos
# permission to the exact binary hash and re-asks on every rebuild. A certificate
# gives the app a designated requirement based on the *cert*, which does not change
# when you recompile -- so the grant sticks.
#
# Entirely local and reversible:  ./setup-signing.sh --remove
set -euo pipefail
cd "$(dirname "$0")"

KEYCHAIN="icloudgui-signing.keychain"
IDENTITY="iCloud GUI Local Signing"
# Not a secret. This password protects a keychain that this script creates on your
# own machine, holding one self-signed certificate used only for local builds. It is
# hardcoded on purpose so the build is reproducible without prompting. Nothing signed
# with it is distributable -- releases use a Developer ID certificate, see RELEASING.md.
PASSWORD="icloudgui-local"

if [[ "${1:-}" == "--remove" ]]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null && echo "Removed $KEYCHAIN" || echo "Nothing to remove"
    exit 0
fi

# No -v here. That flag filters to trust-valid identities, and a self-signed
# certificate never is -- so -v reports nothing, the guard never fires, and the
# script tries to recreate a keychain that already exists.
if security find-identity "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity already present. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> Generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# macOS Security framework cannot read OpenSSL 3's default AES-256 PKCS12 encryption,
# so pin the legacy SHA1/3DES algorithms it does understand.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASSWORD"

# The keychain can exist without the identity, if an earlier run was interrupted
# between the two steps. Reuse it rather than failing.
if security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Reusing existing keychain"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
else
    echo "==> Creating keychain"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"       # no auto-lock timeout
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign -A

# We own this keychain and its password, so codesign can be authorised without a prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

echo "==> Done. Rebuild with ./build.sh -- the Photos grant will now survive rebuilds."
