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

The only way to offer a download that just works. Once set up, a whole release is one
command:

```bash
./ship.sh
```

That signs and notarises, publishes the GitHub release with notes from the changelog,
and bumps the Homebrew cask — see [Step 6](#step-6--ship-it).

`release.sh`, which `ship.sh` calls for the signing, refuses to run until each
prerequisite is in place and tells you which one is missing, so you can run either at
any point to see where you stand. `./ship.sh --dry-run` runs every check and prints what
it would publish without touching Apple, GitHub or the tap.

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

### Step 6 — ship it

```bash
./ship.sh
```

A release lands in three places, and `ship.sh` does all three from one command:

1. **This repository.** Runs `release.sh` (sign, notarise, staple, package, notarise the
   disk image), then `gh release create` — which is also what creates the `v$VERSION`
   tag — attaching `build/iCloud-GUI.dmg`.
2. **The Homebrew tap.** Rewrites `version` and `sha256` in
   `Casks/icloud-gui.rb`, commits and pushes. The hash is taken from the disk image just
   notarised rather than from a re-download of the published one: same bytes, and the
   cask cannot end up describing an artifact we never built.
3. **The website — nothing to do.** `app/lib/release.ts` on the marketing site reads the
   version and the DMG size from the GitHub releases API when the page renders, so
   publishing the release *is* the website update. It appears within the hour, when the
   page's cache revalidates. There is nothing to deploy and no version to bump.

Release notes come from the `## $VERSION` section of `CHANGELOG.md`, so what shipped is
described in one place rather than typed a second time into a `gh` command.

Everything is checked before the first round trip to Apple — on `main`, clean tree, in
sync with `origin`, version not already tagged, changelog section present, tap checkout
present and clean. Finding a missing changelog section after notarisation wastes several
minutes, so it is found first.

```bash
./ship.sh --dry-run       # every check, plus the notes and cask edit it would make
./ship.sh --publish-only  # an already-notarised DMG failed at the publish step
```

`--publish-only` matters on a retry: notarisation is two round trips to Apple, and a
failure in the publish step should not pay for them twice.

`TAP_DIR` defaults to `../homebrew-tap` and overrides where the tap clone lives. Point it
at your own checkout, **not** `/opt/homebrew/Library/Taps/dr-tech-ventures/homebrew-tap`
— `brew update` resets that one, so a commit pushed from it can disappear.

The version itself is not bumped by `ship.sh`. `main` is protected, so
`CFBundleShortVersionString` and `CFBundleVersion` in `build.sh`, plus the new
`CHANGELOG.md` section, go through a pull request with CI green first. `ship.sh` then
ships whatever version `main` says.

`build/` is gitignored — release binaries are attached to the release, never committed.

#### What still needs doing by hand

- **A change to the minimum macOS.** Three strings on the product page
  (`app/products/icloud-gui/page.tsx`: the hero meta line, `operatingSystem` in the
  JSON-LD, and the requirements FAQ) and `depends_on macos:` in the cask. Not a
  per-release job — only when the floor moves.
- **Testing the Photos prompt** on a clean macOS user account.

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

### Why the signing is not automated

**The signing is done by hand, from a Mac. This is deliberate.** `ship.sh` automates
everything *around* it — the tag, the release, its notes, the cask — and deliberately
nothing that would require the Developer ID key to leave this machine.

CI builds every push, pull request and tag, and runs the assertions — but it never
signs or notarises. The artifact it produces is ad-hoc signed and thrown away, because
the runner has no Developer ID identity.

Automating the release would mean putting three secrets in GitHub, one of which is the
**Developer ID certificate and its private key**. That is the key that signs software as
DR Tech Ventures. A copy of it in repository secrets is readable by anyone with admin on
the org, and if it leaks an attacker can sign software macOS will trust as us —
revoking it invalidates our ability to sign until a replacement is issued, and Apple
caps how many a team may hold.

For an occasional release by one maintainer, `./ship.sh` already does the whole sequence
in a single command in a few minutes, and it needs no secrets at all: it uses the
Developer ID certificate in the local keychain, the notarytool profile in the local
keychain, and whatever `gh` and `git` are already authenticated as. The automation would
buy convenience we do not need in exchange for copying the signing identity somewhere it
does not have to be.

The same reasoning rules out bumping the cask from CI. A workflow in the tap triggered by
a release here would need a cross-repository token with write access to the tap stored as
a secret; `ship.sh` does it locally, at the moment the DMG exists, with none.

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

Through a pull request, with CI green:

- [ ] The change itself merged to `main`
- [ ] `./run.sh --self-check` passes
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` bumped in `build.sh`
- [ ] A `## <version>` section added to `CHANGELOG.md` — this becomes the release notes
- [ ] If the minimum macOS moved: `depends_on macos:` in the cask, and the three
      requirement strings on the product page

Then, from a clean `main`:

- [ ] `./ship.sh --dry-run` looks right
- [ ] `./ship.sh` — tags, notarises, publishes, bumps the tap
- [ ] `brew update && brew install --cask dr-tech-ventures/tap/icloud-gui` works
- [ ] Photos prompt tested on a clean user account
- [ ] The product page shows the new version within the hour (it needs no deploy)
