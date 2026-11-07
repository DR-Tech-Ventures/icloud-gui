#!/bin/bash
# Publishes a release in one command.
#
#   ./ship.sh                 build + notarise, publish to GitHub, bump the Homebrew cask
#   ./ship.sh --publish-only  skip the build; publish an already-notarised build/*.dmg
#   ./ship.sh --dry-run       run every check and print what would happen; touch nothing
#
# Signing stays on this Mac on purpose -- see "Why the signing is not automated" in
# RELEASING.md. This script automates everything *around* that: the tag, the GitHub
# release, its notes, and the cask bump. It does not put the Developer ID key anywhere.
#
# The website is deliberately not a step here. app/lib/release.ts on the marketing site
# reads the version and the DMG size from the GitHub releases API when the page renders,
# so publishing the release is what updates the site -- within the hour, when its cache
# revalidates. Only a change to the minimum macOS needs the site edited by hand, and
# that is an OS-bump job, not a per-release one.
#
# TAP_DIR overrides where the tap checkout lives. It must be your own clone --
# NOT /opt/homebrew/Library/Taps/..., which `brew update` resets.
set -euo pipefail
cd "$(dirname "$0")"

TAP_DIR="${TAP_DIR:-$(cd .. && pwd)/homebrew-tap}"
CASK_REL="Casks/icloud-gui.rb"
DMG="build/iCloud-GUI.dmg"

PUBLISH_ONLY=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --publish-only) PUBLISH_ONLY=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

say() { printf '==> %s\n' "$1"; }
die() { printf '\n%s\n\n' "$1" >&2; exit 1; }

# Rewrites the two lines of the cask that change per release. It verifies both landed,
# because a sed whose anchor stopped matching is a silent no-op -- and a cask left on the
# old version and hash is the one failure here that users hit rather than the maintainer.
bump_cask() {
    local cask="$1" version="$2" sha="$3"
    sed -i '' \
        -e "s|^  version \".*\"\$|  version \"$version\"|" \
        -e "s|^  sha256 \".*\"\$|  sha256 \"$sha\"|" \
        "$cask"
    grep -q "^  version \"$version\"\$" "$cask" || die "Could not update the version line in $cask."
    grep -q "^  sha256 \"$sha\"\$" "$cask"      || die "Could not update the sha256 line in $cask."
}

# --- What are we shipping? --------------------------------------------------
# build.sh owns the version, exactly as release.sh reads it, so the two cannot drift.
VERSION="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' build.sh | head -1)"
[ -n "${VERSION:-}" ] || die "Could not read CFBundleShortVersionString from build.sh."
say "Version: $VERSION"

# --- Preflight --------------------------------------------------------------
# All of it before anything irreversible: notarisation is two round trips to Apple, and
# discovering a missing changelog section after that is a waste of several minutes.
command -v gh >/dev/null || die "The GitHub CLI (gh) is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "On branch '$BRANCH'. Releases are cut from main."
[ -z "$(git status --porcelain)" ] || die "Working tree is dirty. Commit or discard first."

git fetch --tags --quiet origin main 2>/dev/null || true
if [ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]; then
    die "origin/main is ahead of this checkout. Pull first."
fi
# And the other direction, which matters more. `gh release create` with no --target tags
# whatever the REMOTE default branch points at, so an unpushed commit here would notarise
# a binary built from code the tag does not name: a signed, published artifact whose
# source is not the tagged source. Nothing downstream would ever flag it.
if [ -n "$(git rev-list origin/main..HEAD 2>/dev/null)" ]; then
    die "This checkout has commits that are not on origin/main. Push them first --
the release tag is created from origin/main, so it would not point at the
code this would build and notarise."
fi
# Belt and braces: pin the tag to the exact commit that gets built, so even a push to
# main between the check above and the release below cannot move it.
TARGET_SHA="$(git rev-parse HEAD)"

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    die "v$VERSION is already tagged, so it has already been published.
Bump CFBundleShortVersionString and CFBundleVersion in build.sh, and add a
'## $VERSION' section to CHANGELOG.md, through a pull request to main."
fi

# Release notes come out of the changelog, so there is one source of truth for what
# changed rather than notes typed a second time into the gh command.
NOTES="$(awk -v v="$VERSION" '$0=="## "v {f=1;next} /^## / && f {exit} f' CHANGELOG.md)"
[ -n "${NOTES//[[:space:]]/}" ] || die "CHANGELOG.md has no '## $VERSION' section to use as release notes."
say "Release notes: $(printf '%s' "$NOTES" | grep -c '') lines from CHANGELOG.md"

CASK="$TAP_DIR/$CASK_REL"
[ -f "$CASK" ] || die "No cask at $CASK
Set TAP_DIR to your homebrew-tap clone, e.g.
  TAP_DIR=~/Documents/GitHub/homebrew-tap ./ship.sh
Do not point it at /opt/homebrew/Library/Taps/... -- brew update resets that clone."
git -C "$TAP_DIR" remote get-url origin | grep -qi 'homebrew-tap' \
    || die "$TAP_DIR does not look like the homebrew-tap repository."
[ -z "$(git -C "$TAP_DIR" status --porcelain)" ] \
    || die "The tap checkout at $TAP_DIR is dirty. Commit or discard first."
TAP_BRANCH="$(git -C "$TAP_DIR" rev-parse --abbrev-ref HEAD)"
[ "$TAP_BRANCH" = "main" ] \
    || die "The tap checkout is on '$TAP_BRANCH', not main. A cask bump pushed from
anywhere else is invisible to everyone running brew."
say "Tap: $TAP_DIR"

if [ "$DRY_RUN" = 1 ]; then
    # Exercises version parsing, the changelog extraction and the cask rewrite against a
    # throwaway copy, so the parts that silently produce a wrong release are the parts
    # this covers. Nothing is built, uploaded, committed or pushed.
    say "DRY RUN -- nothing will be built, published or pushed"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cp "$CASK" "$TMP/cask.rb"
    bump_cask "$TMP/cask.rb" "$VERSION" "0000000000000000000000000000000000000000000000000000000000000000"
    echo
    echo "Would publish: v$VERSION  (title: iCloud GUI $VERSION)"
    echo "Would tag:     ${TARGET_SHA:0:8} -- the commit this checkout is on"
    echo "Would attach:  $DMG"
    echo "Would set cask version/sha256 in $CASK_REL and push to $(git -C "$TAP_DIR" remote get-url origin)"
    echo
    echo "--- release notes ---"
    printf '%s\n' "$NOTES"
    echo "--- end notes ---"
    exit 0
fi

# --- Build, sign, notarise --------------------------------------------------
if [ "$PUBLISH_ONLY" = 1 ]; then
    [ -f "$DMG" ] || die "--publish-only needs an existing $DMG. Run without it."

    # Everything below is here because a leftover disk image from an EARLIER version
    # passes every signature check there is while containing the wrong build. Signing
    # and notarisation say "Apple vouches for these bytes", not "these bytes are the
    # version you are about to claim they are". Without this, --publish-only will
    # cheerfully publish v1.4.1 with 1.4's binary inside and a matching checksum in the
    # cask, so every check downstream agrees with every other one and all of them are
    # describing the wrong app.
    say "Checking the existing $DMG before publishing it"

    xcrun stapler validate "$DMG" >/dev/null 2>&1 \
        || die "$DMG has no stapled notarisation ticket.
Run without --publish-only to build and notarise $VERSION."
    spctl -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1 \
        || die "Gatekeeper does not accept $DMG.
Run without --publish-only to build and notarise $VERSION."

    # Read the version out of the image itself. The filename carries no version, so it
    # is the only thing that can distinguish this build from last release's.
    MNT="$(mktemp -d)"
    hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet -readonly \
        || die "Could not mount $DMG to check which version it contains."
    DMG_VERSION="$(plutil -extract CFBundleShortVersionString raw \
                   "$MNT/iCloud GUI.app/Contents/Info.plist" 2>/dev/null || true)"
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
    rmdir "$MNT" 2>/dev/null || true

    [ "$DMG_VERSION" = "$VERSION" ] || die "$DMG contains version ${DMG_VERSION:-unknown}, but this would publish $VERSION.
That disk image is from an earlier release. Run without --publish-only."

    say "Skipping the build; publishing the existing $DMG (verified $DMG_VERSION)"
else
    ./release.sh
fi
[ -f "$DMG" ] || die "release.sh did not leave a disk image at $DMG."

# --- Publish ----------------------------------------------------------------
# --target pins the tag to the commit verified in preflight, rather than letting gh take
# whatever origin/main points at now. This is the step that makes the version real.
say "Creating GitHub release v$VERSION"
NOTES_FILE="$(mktemp)"; trap 'rm -f "$NOTES_FILE"' EXIT
printf '%s\n' "$NOTES" > "$NOTES_FILE"
gh release create "v$VERSION" "$DMG" \
   --repo DR-Tech-Ventures/icloud-gui \
   --target "$TARGET_SHA" \
   --title "iCloud GUI $VERSION" \
   --notes-file "$NOTES_FILE"

# --- Bump the Homebrew cask -------------------------------------------------
# Deliberately after the release exists: a cask bumped first points at a download that
# has not been uploaded yet, and anyone installing in between gets a 404.
#
# The hash is taken from the disk image we just notarised, not from a re-download of the
# published one: it is the same bytes, and this way the cask cannot end up describing an
# artifact we never built.
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
say "Bumping the cask to $VERSION ($SHA)"
bump_cask "$CASK" "$VERSION" "$SHA"
git -C "$TAP_DIR" add "$CASK_REL"
git -C "$TAP_DIR" commit -q -m "icloud-gui $VERSION"
git -C "$TAP_DIR" push -q
say "Tap pushed"

cat <<DONE

Published v$VERSION.

  Release   https://github.com/DR-Tech-Ventures/icloud-gui/releases/tag/v$VERSION
  Install   brew install --cask dr-tech-ventures/tap/icloud-gui

Worth checking:
  - brew update && brew install --cask dr-tech-ventures/tap/icloud-gui   (on a clean Mac)
  - the Photos prompt, on a clean macOS user account
  - drtechventures.com/products/icloud-gui picks up $VERSION within the hour by itself;
    it reads the releases API, so there is nothing to deploy. If the minimum macOS
    changed, that page needs editing by hand.
DONE
