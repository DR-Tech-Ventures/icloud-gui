# Distributing builds

**Short version: recommend building from source. Shipping a downloadable `.app` that
works cleanly requires a paid Apple Developer account, and there is no good free
substitute.**

## Why this is harder than it looks

macOS gates two separate things, and both matter here:

1. **Gatekeeper.** A `.app` downloaded from the internet carries a quarantine
   attribute. Unless it is signed with a Developer ID *and notarised by Apple*, macOS
   refuses to open it — and on recent versions the old right-click → Open trick no
   longer works. The user has to go into System Settings → Privacy & Security and click
   "Open Anyway" past a warning that says the app may be malware.
2. **TCC (the Photos permission).** Photos access is tied to the code signature. An
   ad-hoc signature has no stable identity, so the grant is pinned to the exact binary
   hash. This is fine locally; it is not a good basis for distribution.

For an app whose entire premise is *"you never have to hand over your Apple ID
password"*, telling people to bypass Gatekeeper is a bad trade. Do not make that the
default path.

## Option 1 — build from source (recommended, free)

This is the honest recommendation for a tool like this, and it is genuinely easy
because the project has **no dependencies and no Xcode project**:

```bash
git clone <repo-url>
cd iCloud_GUI
./setup-signing.sh
./run.sh
```

A locally built app is never quarantined, so Gatekeeper is not involved at all. Users
need the Xcode command line tools (`xcode-select --install`), which is the only real
friction.

## Option 2 — signed and notarised releases ($99/year)

The only way to offer a download that just works.

**You need:** an [Apple Developer Program](https://developer.apple.com/programs/)
membership, and a **Developer ID Application** certificate (not "Mac App Distribution" —
that one is for the App Store).

The build differs from the local one in two ways:

- Sign with the Developer ID certificate instead of `-` or the local identity.
- **Add `--options runtime`.** Notarisation requires hardened runtime. It is safe here,
  unlike with local signing, because a Developer ID certificate carries a real Team ID —
  which is exactly what TCC wants in order to show the Photos prompt.

```bash
codesign --force --deep --timestamp --options runtime \
         --sign "Developer ID Application: YOUR NAME (TEAMID)" \
         --identifier com.local.icloudgui \
         "build/iCloud GUI.app"

ditto -c -k --keepParent "build/iCloud GUI.app" iCloudGUI.zip

xcrun notarytool submit iCloudGUI.zip \
      --apple-id "you@example.com" --team-id TEAMID \
      --password "app-specific-password" --wait

xcrun stapler staple "build/iCloud GUI.app"
```

Then zip the stapled `.app` and attach it to a GitHub Release.

**Verify before publishing** — on a Mac that has never run the app:

```bash
spctl -a -vvv "build/iCloud GUI.app"        # should say: accepted, Notarized Developer ID
xcrun stapler validate "build/iCloud GUI.app"
```

**Test the Photos prompt on a clean machine or a fresh user account.** Local signing and
Developer ID signing behave differently with TCC, and this project has already been
bitten once by hardened runtime silently suppressing the prompt. Do not assume it works
because it worked locally.

Notes:
- Change `CFBundleIdentifier` in `build.sh` from `com.local.icloudgui` to a reverse-DNS
  identifier you control before publishing binaries.
- Automating this in GitHub Actions means putting the certificate (`.p12`, base64) and
  an app-specific password in repository secrets.

## Option 3 — unsigned release (not recommended)

You *can* attach an ad-hoc signed `.app` to a release, but every user has to strip the
quarantine attribute by hand:

```bash
xattr -dr com.apple.quarantine "/Applications/iCloud GUI.app"
```

Teaching people to run that on an app that reads their entire photo library is a poor
habit to spread, and it is not obviously better than having them build from source. If
you do it anyway, say plainly in the release notes what the command does and why it is
needed.

## Release checklist

- [ ] `./run.sh --self-check` passes
- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `build.sh`
- [ ] Tag the release
- [ ] If shipping a binary: signed, notarised, stapled, and `spctl` verified
- [ ] Photos prompt tested on a clean user account
