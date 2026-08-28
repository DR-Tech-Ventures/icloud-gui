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
| `--updates` | The update check, without the menu item: the request, GitHub's response shape and the version comparison. |
| `--shot 1000x700` | Captures the window to `/tmp/icg-shot.png`. Needs no Screen Recording permission. |
| `--demo` | Generic album names and generated tiles, for screenshots. |
| `--album <name>` | Select an album before capturing. |
| `--group day\|month\|year` | Set the grid grouping before capturing. |

**Always use `--demo` for any screenshot that will be published.** A screenshot of a
photo app leaks twice over: the photos, and the sidebar, which lists the album names
people give to their children, relatives and holidays. Demo mode substitutes both while
leaving the interface, layout and live scan output real.

```bash
open "build/iCloud GUI.app" --args --demo --shot 1280x840 --album "All Photos" --group month
```

`--shot` goes through `CGWindowListCreateImage` on the app's own window, which needs no
Screen Recording grant. It cannot fall back to rendering the layer tree and stay
correct: Liquid Glass draws the sidebar, the toolbar and every control bezel in backdrop
layers that sit outside the view hierarchy, so a layer render captures them as blank
white. That fallback is still in `Shot.swift` for a machine old enough not to have glass.

Keep captures at or above the 1180pt minimum window width — narrower and macOS folds the
toolbar's trailing items, Download included, behind a `»` overflow menu.

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

## Raising the deployment target

`Package.swift` is the single source for it -- `build.sh` reads `.macOS(.vNN)` from
there, stamps it into the binary as `minos` and writes it to `LSMinimumSystemVersion`, so
there is nothing to keep in sync by hand.

One thing blocks raising it above macOS 14 today. `Shot.swift` captures the window with
`CGWindowListCreateImage`, which the SDK marks **obsoleted in macOS 15.0**. At a
deployment target of 14 that is a warning; at 15 or higher it is a hard `unavailable`
error and the build stops. It is used because it is the only way to capture the app's own
window without the Screen Recording permission, which the documentation screenshots
depend on. Whoever raises the target has to replace it first -- ScreenCaptureKit plus a
permission prompt, or dropping `--shot` and capturing by hand.

## Where the logs are

Three places, none of which is a file the app invents:

| What | Where | Covers |
|---|---|---|
| Lifecycle breadcrumbs | macOS unified log, subsystem `com.drtechventures.icloudgui` | Launch, Photos authorisation, album loads, clean termination |
| Crash reports | `~/Library/Logs/DiagnosticReports/` | Actual crashes, symbolicated, written by macOS |
| Download failures | `.icloudgui-log.txt` in the destination folder | Per-run start/failure/end, written unbuffered |

```bash
log show --predicate 'subsystem == "com.drtechventures.icloudgui"' --last 1h --style compact
```

The useful trick is the absence of a line: every launch logs `launched`, and every
orderly quit logs `terminating normally`. A `launched` with no matching terminate means
the process was killed — by the system, by `pkill`, or by a rebuild deleting its bundle.
No crash report is written in that case, which is why "no crash report" does not mean
"did not stop".

`Log.swift` uses `os.Logger`, so interpolated values are redacted as `<private>` unless
explicitly marked `.public`. Keep paths, album names and filenames out of the public
ones — this log is readable by anything on the machine that asks for it.

**There is deliberately no crash-reporting service.** Sentry and its kind would mean a
third-party dependency, a network connection the app otherwise does not make, and crash
payloads carrying file paths — which for this app means album names, photo filenames and
the user's home directory. macOS already writes better native crash reports locally, and
a bug report can attach one. See SECURITY.md.

## The app icon

Two icons ship, from one design, and neither is hand-drawn.

| File | Used by | Made by |
|---|---|---|
| `Icon/AppIcon.icns` | macOS 14-25 | `Icon/make-icon.swift`, rendered per size 16 to 1024 |
| `Icon/AppIcon.icon` | macOS 26+ | `icon.json` (committed) plus a glyph PNG from the same script |

`./Icon/make-icon.sh` regenerates both. `build.sh` compiles the `.icon` with `actool`
into `Assets.car` and adds `CFBundleIconName`; the `.icns` is copied in alongside it with
`CFBundleIconFile`. macOS 26 prefers the first, older versions ignore it and use the
second, so both keys are correct at once.

**The layered icon is optional at build time.** `actool` lives inside `Xcode.app` and is
*not* in the standalone Command Line Tools, which this project has otherwise never
needed. Without Xcode the build prints `Layered icon skipped` and ships only the `.icns`
-- the app is fine, it just gets the flat icon on Tahoe. CI has Xcode and asserts the
layered icon was produced, because a silent skip is the failure mode worth catching.

### Why the layers carry no container

`icon.json` is an `automatic-gradient` fill and one layer holding the glyph. There is no
background image, no rounded rectangle, no shadow and no specular highlight, because on
macOS 26 the system draws all four itself and differently per appearance -- default,
dark, clear and tinted. A layer that brings its own gets a second squircle inside the
real one and a shadow that does not move with the light.

The `.icns` bakes all of it in, because macOS 14-25 draw none of it.

### Editing it

The gradient colour is one line in `Icon/AppIcon.icon/icon.json`. The glyph comes from
`drawGlyph` in `make-icon.swift`. `AppIcon.icon` is a real Icon Composer document, so
*Xcode > Open Developer Tool > Icon Composer* opens it for visual editing -- but nothing
in the pipeline needs that app, and the format is plain JSON beside a PNG.

Do not judge the result from the glyph PNG alone; it is only the middle of the picture.
Ask macOS what it actually draws, which is what Finder and the Dock show, container and
lighting included:

```swift
NSWorkspace.shared.icon(forFile: "build/iCloud GUI.app")
```

## Releasing

`./release.sh` handles signing, notarisation and stapling. It checks its prerequisites
first and tells you what is missing, so running it is a safe way to see where you stand.
Setup is documented in [RELEASING.md](RELEASING.md).

## Style

Match the surrounding code. Comments explain *why*, especially where behaviour looks
surprising — most of the non-obvious code here exists because of an Apple restriction
that cost an afternoon to find. Say which one.
