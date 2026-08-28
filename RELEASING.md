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
staples the ticket into the `.app`, verifies with `spctl`, packages the stapled app into
a disk image alongside an `/Applications` symlink, then signs, notarises and staples the
disk image too.

**That is two round trips to Apple, not one** — a few minutes each. The app and the disk
image are separate artifacts with separate signatures, and a notarised app inside an
un-notarised container still makes Gatekeeper check online at first launch, which fails
on a machine that happens to be offline.

### Step 6 — publish it

`release.sh` leaves the distributable at **`build/iCloud-GUI.dmg`**. Attach it to a
GitHub Release:

```bash
gh release create v1.2 "build/iCloud-GUI.dmg" \
   --repo DR-Tech-Ventures/icloud-gui \
   --title "iCloud GUI 1.2" \
   --notes "Download your iCloud photos to a Mac or NAS. Signed and notarised by Apple, so it opens without any Gatekeeper warnings."
```

Keep the tag matching `CFBundleShortVersionString` in `build.sh` — `release.sh` refuses
to build a version that is already tagged, and that check is what stops two different
builds going out under one version number.

`build/` is gitignored — release binaries are attached to the release, never committed.

### Why you cannot just zip a development build

The output of `build.sh` is signed with an ad-hoc or self-signed certificate. That is
fine locally, where nothing is quarantined. Once it has been downloaded, macOS attaches
a quarantine flag and Gatekeeper refuses it outright:

```
$ spctl -a -vvv "iCloud GUI.app"
iCloud GUI.app: rejected
origin=iCloud GUI Local Signing
```

Only a notarised build gets `accepted / Notarized Developer ID`. There is no way around
this short of asking every user to strip the quarantine attribute by hand — see Option 3.

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

### Why releases are not automated

**They are cut by hand, from a Mac. This is deliberate.**

CI builds every push, pull request and tag, and runs the assertions — but it never
signs or notarises. The artifact it produces is ad-hoc signed and thrown away, because
the runner has no Developer ID identity.

Automating the release would mean putting three secrets in GitHub, one of which is the
**Developer ID certificate and its private key**. That is the key that signs software as
DR Tech Ventures. A copy of it in repository secrets is readable by anyone with admin on
the org, and if it leaks an attacker can sign software macOS will trust as us —
revoking it invalidates our ability to sign until a replacement is issued, and Apple
caps how many a team may hold.

For an occasional release by one maintainer, `./release.sh` already does the whole
sequence in a single command in a few minutes. The automation would buy convenience we
do not need in exchange for copying the signing identity somewhere it does not have to
be.

**Revisit this if** someone else needs to cut releases, or releases become frequent
enough that the manual step is real friction. The workflow would import a base64 `.p12`
into a temporary keychain and run the same `codesign` / `notarytool` / `stapler`
sequence with `--password` in place of `--keychain-profile`, triggered on tags, ideally
behind a `release` environment requiring manual approval.

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

## Branch protection

`main` requires a pull request and a green `build` check, enforced for administrators
too. To restore the rule if it is ever lifted:

```bash
gh api -X PUT repos/DR-Tech-Ventures/icloud-gui/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["build"] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

`required_approving_review_count` is 0 deliberately: a pull request is required, but a
sole maintainer cannot approve their own, and requiring one would make merging
impossible.

## Release checklist

- [ ] The change merged to `main` through a pull request with CI green
- [ ] `./run.sh --self-check` passes
- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `build.sh`
- [ ] Tag the release
- [ ] If shipping a binary: signed, notarised, stapled, and `spctl` verified
- [ ] Photos prompt tested on a clean user account
