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
git clone https://github.com/DR-Tech-Ventures/icloud-gui
cd icloud-gui
./setup-signing.sh
./run.sh
```

A locally built app is never quarantined, so Gatekeeper is not involved at all. Users
need the Xcode command line tools (`xcode-select --install`), which is the only real
friction.

## Option 2 — signed and notarised releases ($99/year)

The only way to offer a download that just works. Once set up, the whole thing is:

```bash
./release.sh
```

`release.sh` refuses to run until each prerequisite is in place and tells you which one
is missing, so you can run it at any point to see where you stand.

### Step 1 — confirm you have a *paid* membership

Sign in at [developer.apple.com/account](https://developer.apple.com/account).

A **free** Apple ID gets you `Apple Development` certificates, which are for running
your own builds on your own devices. They **cannot notarise**. Only the paid
[Apple Developer Program](https://developer.apple.com/programs/) ($99/year) can issue
the `Developer ID Application` certificate this needs.

Check what you already have:

```bash
security find-identity -v -p codesigning
```

`Apple Development: …` is not enough. You are looking for `Developer ID Application: …`.

### Step 2 — create the Developer ID Application certificate

> This project is set up for **DR Tech Ventures LLC** (Team ID `DJ2RANBKU3`), an
> Organization account. Only the **Account Holder** or an **Admin** on that team can
> create Developer ID certificates, and Apple caps how many a team may hold — so if one
> already exists on another Mac, export it as a `.p12` and import it here rather than
> creating another.

Easiest route, which handles the private key for you:

> **Xcode → Settings → Accounts → select your team → Manage Certificates → + →
> Developer ID Application**

Manual route, if you prefer: create a Certificate Signing Request in Keychain Access
(*Keychain Access → Certificate Assistant → Request a Certificate From a Certificate
Authority*, saved to disk), upload it under Certificates on the developer site, choose
**Developer ID Application**, then download and double-click the resulting `.cer`.

**Back up this certificate and its private key.** Export both as a `.p12` from Keychain
Access and keep it somewhere safe — Apple limits how many Developer ID certificates you
can create, and losing the private key is a genuine problem.

### Step 3 — create an app-specific password

At [appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security** →
**App-Specific Passwords** → generate one for notarisation.

This is **not** your Apple ID password. Never put your real password into a script,
a CI secret, or a terminal command.

### Step 4 — store the notarisation credentials

```bash
xcrun notarytool store-credentials icloudgui-notary       --apple-id "you@example.com" --team-id "DJ2RANBKU3"
```

It prompts for the app-specific password from step 3 and saves everything in your
keychain, so the password never appears in a script or your shell history.

### Step 5 — release

```bash
BUNDLE_ID=com.yourdomain.icloudgui ./release.sh
```

That builds, signs with hardened runtime, submits to Apple, waits for the result,
staples the ticket into the `.app`, verifies with `spctl`, and produces a zip ready to
attach to a GitHub Release.

### Two things that need real testing

- **The Photos prompt.** Hardened runtime is *required* for notarisation and *breaks*
  TCC when combined with local signing — this project has already lost an afternoon to
  that exact failure, where the prompt silently never appears and access returns
  `denied`. It should work with a Developer ID certificate, because that carries a real
  Team ID. Verify it rather than assume: test on a clean macOS user account, not the
  machine you built on.
- **The entitlement.** `release.entitlements` requests
  `com.apple.security.personal-information.photos-library`, the hardened-runtime
  Resource Access entitlement for the photo library. It is harmless if redundant. If the
  prompt fails to appear, this is the first thing to try toggling.

### Automating it in GitHub Actions

You need two repository secrets:

- The certificate and key as a base64 `.p12`
  (`base64 -i cert.p12 | pbcopy`), plus its export password
- The app-specific password, apple-id and team-id

The workflow imports the `.p12` into a temporary keychain, then runs the same
`codesign` / `notarytool` / `stapler` sequence with `--password` instead of
`--keychain-profile`. Keep it on a tag trigger so it only runs for releases.

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
