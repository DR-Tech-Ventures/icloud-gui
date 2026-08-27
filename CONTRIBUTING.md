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

## Before opening a PR

```bash
./run.sh --self-check
```

All assertions must pass. CI runs the same command on every PR.

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
