# Contributing

## Getting set up

```bash
git clone https://github.com/DR-Tech-Ventures/icloud-gui
cd icloud-gui
./setup-signing.sh   # once: local signing identity so Photos grants survive rebuilds
./run.sh             # build and launch
```

You need macOS 14+ and the Xcode command line tools. There are **no third-party
dependencies** and no Xcode project — `swift build` plus a shell script that assembles
the `.app`. Please keep it that way unless there is a strong reason not to.

## The workflow

`main` is protected: it cannot be pushed to directly, by anyone, including
administrators. Every change goes through a pull request, and CI must be green before it
can merge.

```bash
git checkout -b feature/short-name
# ... work ...
./run.sh --self-check
git push -u origin feature/short-name
gh pr create --fill
gh pr merge --squash --delete-branch    # once CI is green
```

History is linear — merges are squashed, not merge-committed. Approvals are not
required, so a solo maintainer is not blocked, but the pull request and a passing build
are.

If you genuinely need to bypass this (a broken `main`, say), lift the rule, push, and put
it back:

```bash
gh api -X DELETE repos/DR-Tech-Ventures/icloud-gui/branches/main/protection
# ... fix ...
# then re-apply it; the settings are recorded in RELEASING.md
```

## The pipeline, end to end

```
  branch  ──▶  push  ──▶  pull request  ──▶  main  ──▶  tag v*  ──▶  release
                             │                 │           │            │
                             ▼                 ▼           ▼            ▼
                        CI: build          CI: build   CI: build   ./release.sh
                        + self-check       + self-check + self-check  by hand
                                                                   on a Mac
```

**What CI runs** (`.github/workflows/ci.yml`, `macos-15`):

| Step | What it proves |
|---|---|
| `swift build -c release` | It compiles on a clean machine with no local state |
| `iCloudGUI --self-check` | All assertions pass. Exits non-zero on the first failure. |
| `./build.sh release` | The `.app` bundle assembles and signs |

**What triggers it:** every pull request, every push to `main`, and every `v*` tag.

**What CI does not do:** sign or notarise a release. The bundle it assembles is ad-hoc
signed, because the runner has no Developer ID identity, and it is discarded. Releases
are cut by hand — [RELEASING.md](RELEASING.md) explains why, and it is a decision rather
than an omission.

**What CI cannot cover:** anything touching PhotoKit needs a real photo library and a
signed-in iCloud account. That is why every decision which could lose a photo lives in a
pure function — resource selection, path building, collision handling, the incremental
diff — and why the assertions can run on a runner with no photos at all.

**When CI fails:** `gh run view --log-failed` shows the failing step. It has already
caught a real portability bug that could not reproduce locally, where an API existed on
the newer SDK used for development but not on the runner's.

## Every pull request carries its documentation

A change and the documentation describing it go in the **same pull request**. Before
opening one, check whether it touches anything described in `README.md`, this file,
`RELEASING.md`, `SECURITY.md`, or the in-app guide in `Guide.swift`.

**Bump the version** in `build.sh` — both `CFBundleShortVersionString` and
`CFBundleVersion` — whenever anything under `Sources/` or `build.sh` changes, and add a
`CHANGELOG.md` entry. Tooling-only changes (CI, scripts) need neither: `CHANGELOG.md`
tracks what a user of the app can observe.

`release.sh` refuses to build a version that already has a tag, so a forgotten bump
fails in a second rather than after a round trip to Apple's notary service.

## Before opening a PR

```bash
./run.sh --self-check
```

All assertions must pass. CI runs the same command on every pull request, every push to
`main`, and every `v*` tag — so a released commit is known to build and pass its
assertions on a clean machine.

CI does not sign or notarise. Releases are cut by hand from a Mac with `./release.sh`,
so the Developer ID signing key never leaves it. `RELEASING.md` explains that choice.

**Non-trivial logic should leave a check behind.** The self-check is plain asserts — no
test framework, no fixtures. Add cases to `SelfCheck.swift` next to the existing ones.
Prefer testing a *pure* function: that is why resource selection, path building,
collision handling, date grouping and the incremental diff are all separated from
PhotoKit and from the UI.

## What is hard to test, and how we handle it

Anything touching PhotoKit needs a real photo library, so it cannot run in CI. The
pattern used throughout is to keep the decision pure and testable, and leave only the
PhotoKit call untested:

- `planResources` decides *which* resources to keep — pure, tested.
- `relativePath` / `uniqueURL` decide *where* files go — pure, tested.
- `missingPaths` decides *what is already downloaded* — pure, tested.

There are diagnostic flags for the parts that need a real library. They print to
`/tmp` and exit, so they are safe to run any time:

| Flag | What it reports |
|---|---|
| `--self-check` | The assertions. Exits non-zero on failure. |
| `--status` | Photos authorisation, without triggering a prompt. |
| `--probe` | Authorisation before/after a request, plus asset count. |
| `--albums` | Every collection, with counts under different fetch options. |
| `--hidden` | Why the Hidden album is empty. |
| `--extras` | Burst frames, UUID filenames, favourites, locations. |
| `--size` | Estimated size of a full backup. |
| `--shot 1000x700` | Renders the window to `/tmp/icg-shot.png`. Needs no Screen Recording permission. |
| `--demo` | Generic album names and generated tiles, for screenshots. |
| `--album <name>` | Select an album before capturing. |
| `--group day\|month\|year` | Set the grid grouping before capturing. |

**Always use `--demo` for any screenshot that will be published.** A screenshot of a
photo app leaks twice over: the photos, and the sidebar, which lists the album names
people give to their children, relatives and holidays. Demo mode substitutes both while
leaving the interface, layout and live scan output real.

```bash
open "build/iCloud GUI.app" --args --demo --shot 1200x760 --album "All Photos" --group month
```

Run them like this:

```bash
open "build/iCloud GUI.app" --args --albums && sleep 8 && cat /tmp/icg-albums.txt
```

## Things worth knowing before you change them

These were each found the hard way. The comments in the code say so too.

- **Never add `--options runtime` to the local signing paths in `build.sh`.** Hardened
  runtime requires a real Team ID for privacy-sensitive access. With an ad-hoc or
  self-signed certificate, macOS silently returns `denied` for Photos and never shows a
  prompt. (Notarised release builds are the exception — see `RELEASING.md`.)
- **`PHAccessLevel` has no read-only option.** `.readWrite` is the only level that
  grants read. The app never writes to the library.
- **Some smart albums are omitted from a `.any` enumeration** but returned when
  requested by subtype (Recently Added is one). `loadAlbums` does both passes and merges.
- **A file's existence is not proof you have that photo.** Two photos from different
  devices can both be `IMG_0001.HEIC` on the same day. That is what the ledger is for.
- **Bursts hide frames.** PhotoKit returns one representative per burst unless asked
  otherwise; `expandingBursts` recovers the rest.
- **Shared albums are downscaled by iCloud** (~2048px, video 720p). Not a bug.
- **Hidden and Recently Deleted are macOS restrictions**, not missing features. Neither
  is reachable by any third-party app. Both are listed in the sidebar deliberately.

## The app icon

`Icon/AppIcon.icns` is generated, not hand-drawn — `Icon/make-icon.swift` draws it and
`./Icon/make-icon.sh` regenerates the `.icns`. Committing the source rather than only a
binary means the design can actually be edited.

## Releasing

`./release.sh` handles signing, notarisation and stapling. It checks its prerequisites
first and tells you what is missing, so running it is a safe way to see where you stand.
Setup is documented in [RELEASING.md](RELEASING.md).

## Style

Match the surrounding code. Comments explain *why*, especially where behaviour looks
surprising — most of the non-obvious code here exists because of an Apple restriction
that cost an afternoon to find. Say which one.
