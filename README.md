# iCloud GUI

A small macOS app to browse your iCloud Photos library and download originals to a
local folder or a mounted NAS share.

## Why it works this way

There is **no official iCloud Photos API** for third-party apps. There are two ways in:

1. **Reverse-engineered web API** (`pyicloud` / `icloudpd`) — needs your Apple ID
   password, and only works if you turn **Advanced Data Protection off** and enable
   "Access iCloud Data on the Web". Apple also blocks it periodically.
2. **PhotoKit** — Apple's sanctioned framework. This app uses it.

With PhotoKit, macOS itself is already signed into iCloud. The app asks the system
for Photos access, and `PHAssetResourceManager` with `networkAccessAllowed = true`
pulls the **full-resolution originals** down from iCloud on demand.

That means:

- No Apple ID password is ever requested, entered, or stored.
- Two-factor authentication is a non-issue.
- **Advanced Data Protection can stay on.**
- Apple can't break it — it's a public API.

The tradeoff: macOS only, and the Photos app must be signed in with iCloud Photos enabled.

> The permission prompt says *full access* because `PHAccessLevel` has only
> `addOnly` and `readWrite` — there is no read-only level to ask for.
> This app only ever reads; it never modifies your library.

## The built-in guide

On first launch the app opens a guide covering how it works, the four download steps,
every option, and the limits macOS imposes — including **step-by-step instructions for
unlocking Hidden photos and recovering deleted ones**. It is **not** a one-shot splash screen —
reopen it any time from **Help → iCloud GUI Guide** (⌘?) or the **?** button in the
bottom bar.

To see the first-run version again:

```bash
defaults delete com.drtechventures.icloudgui hasSeenGuide
```

## Installing

**Build it yourself.** There are no dependencies and no Xcode project, so this is three
commands — and a locally built app is never quarantined, so macOS Gatekeeper never gets
in the way:

```bash
git clone https://github.com/DR-Tech-Ventures/icloud-gui
cd icloud-gui
./setup-signing.sh   # once, so the Photos grant survives rebuilds
./run.sh
```

If a downloadable build is ever published it will be signed and notarised by Apple.
Anything else would mean asking you to bypass Gatekeeper on an app that reads your
entire photo library — see [RELEASING.md](RELEASING.md) for why that is not offered.

## Requirements

- macOS 14+
- Photos app signed into iCloud with **iCloud Photos** turned on
  (System Settings › [your name] › iCloud › Photos)
- Xcode command line tools (for building)

## Build and run

```bash
./run.sh
```

Builds a release bundle and launches it. To build without launching:

```bash
./build.sh
```

The result is `build/iCloud GUI.app` — move it to `/Applications` if you want to keep it.

## Permissions, and why rebuilding re-prompts

macOS gates Photos access through TCC, which identifies an app by its bundle ID **and
its code signature**. An ad-hoc signature has no stable identity, so TCC pins the grant
to the exact binary hash — and every rebuild changes that hash, meaning macOS re-asks
for Photos access every single time you recompile.

Run this **once** to stop that:

```bash
./setup-signing.sh
```

It creates a local self-signed code-signing certificate in its own keychain. The app's
designated requirement then references the *certificate* rather than the code hash:

```
designated => identifier "com.drtechventures.icloudgui" and certificate leaf = H"650c6db…"
```

That does not change when you recompile, so the Photos grant sticks. You will be asked
to grant access once more after the first signed build, then never again.

Entirely local and reversible — `./setup-signing.sh --remove` deletes the keychain, and
`build.sh` falls back to ad-hoc signing if the identity is absent. No Apple Developer
account is involved.

### If the prompt never appears and access is denied instantly

Almost certainly hardened runtime. **Never add `--options runtime` to the `codesign`
call in `build.sh`** — it makes macOS require a real Team ID to establish provenance
for privacy-sensitive access, and an ad-hoc signature has none, so TCC returns
`denied` without ever showing a dialog.

Diagnose it without guessing:

```bash
open "build/iCloud GUI.app" --args --probe && sleep 5 && cat /tmp/icloudgui-probe.txt
```

That reports the bundle ID, whether the usage description is present, and the Photos
status before and after the request. `--status` reports the status read-only, without
triggering a prompt.

To clear a stuck grant and start fresh:

```bash
tccutil reset Photos com.drtechventures.icloudgui
```

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
setup, the diagnostic flags, and a list of the Apple restrictions that look like bugs
but are not. Licensed under [MIT](LICENSE).

## Self-check

The download-planning logic (which resources to keep, filename and collision rules)
is pure and covered by assertions:

```bash
./run.sh --self-check
```

## Using it

1. Click **Grant Photos Access** and approve the system prompt.
2. Pick an album in the sidebar — All Photos, smart albums, and your own albums.
3. Click thumbnails to select. **Selecting nothing downloads the whole album.**
4. Choose a **Destination** — any local folder, or a mounted NAS share.
5. **Download.**

Files land as `Destination/YYYY/YYYY-MM-DD/IMG_1234.HEIC`.

## Folder layout

Two options, switchable in the bottom bar:

| Option | Result |
|---|---|
| **Date folders** (default) | `2024/2024-03-15/IMG_1234.HEIC` |
| **One folder** | `IMG_1234.HEIC` — everything side by side |

Both are in the **File Options** menu, along with date-prefixed filenames, pre-edit
originals, and Finder tags.

Flat layout makes same-name collisions far more likely (`IMG_0001.HEIC` recurs across
devices and years). Those get a ` (2)` suffix, and because the index records the name
actually used, repeat runs stay stable instead of renumbering.

**Switching layout affects new downloads only.** Files already on disk stay where they
are — the index knows you already have them, so nothing is re-fetched. Reorganising an
existing 200 GB backup is a job for `mv`, not a re-download.

## Albums

The sidebar is grouped and sorted:

- **Library** — All Photos, Hidden, Recently Deleted
- **Smart Albums** — Favorites, Recently Added, Videos, Live Photos, Selfies,
  Screenshots, Screen Recordings, Panoramas, Bursts, Slo-mo, Time-lapse, RAW,
  Cinematic, Portrait, Long Exposure, Animated (empty ones are omitted)
- **My Albums** — your own albums, alphabetical
- **Shared Albums** — iCloud Shared Albums, alphabetical

### Hidden — supported, but macOS may be withholding them

The app sets `includeHiddenAssets` for the Hidden album. Whether you actually get
anything is up to macOS:

**While the Hidden album requires Touch ID or a password, macOS returns nothing to any
third-party app** — even one with full Photos access. This is deliberate and there is
no API around it. Measured on a locked library: the Hidden collection exists, reports
0 under every fetch option, and `isHidden` is `false` on all 35,815 assets. The photos
are simply not handed over.

To download hidden photos:

1. Open **Photos** → **Settings** (⌘,) → **General**
2. Turn off **"Use Touch ID or Password"**
3. Back in iCloud GUI, click the rescan button

The Hidden row is always listed, showing **—** rather than a count, and clicking it
explains the setting instead of showing a bare "empty album".

### Recently Deleted — genuinely impossible

**PhotoKit has no Recently Deleted collection.** The subtype enum runs 200–220 with no
trash entry, there is no reference to it anywhere in the framework headers, and
enumerating *every* smart album PhotoKit will return does not produce one. This is not
a gap in this app — no third-party application on macOS can read Recently Deleted.

Having items in Recently Deleted is expected and normal; they are simply invisible to
everything except Apple's own Photos app.

Recently Deleted is still **listed in the sidebar**, showing **—**, because silently
omitting it makes an Apple restriction look like a missing feature — and it is the first
place people go looking. Clicking it explains the situation.

**Workaround:** in Photos, open **Recently Deleted**, select what you want and click
**Recover**. Those photos return to your library and appear here on the next rescan.

### Smart albums beyond the documented list

Albums are collected two ways and merged: each known subtype is requested by name, then
everything else PhotoKit will return is swept up. Both passes are needed — PhotoKit
omits some albums (Recently Added among them) from a bulk `.any` enumeration but returns
them when asked for specifically, while undocumented ones (**Captured by Me**,
**Recently Saved**, **Dual Capture**) only appear in the bulk pass.

### Shared albums are not full resolution

Shared albums can be browsed and downloaded, but **iCloud stores reduced-size copies in
them.** Measured on a real library:

| | Resolution |
|---|---|
| Own library | 4284×5712 |
| Shared album | 1537×2049, 1068×1079 · video 720×1280 |

So shared albums cap around 2048px on the long edge, video at 720p. That is Apple's
storage format, not a limitation of this app — the full-resolution original lives in
the *owner's* library. The app shows this warning when a shared album is selected, so
nobody mistakes it for a full-resolution backup.

## What gets downloaded

For each item, the app keeps what a backup should actually keep:

| Situation | Result |
|---|---|
| Plain photo | the original |
| Edited photo | the **edited** version (toggle **Keep pre-edit originals** to get both, original suffixed `_original`) |
| Live Photo | the still **and** the paired `.mov` |
| RAW + JPEG | **both** — the RAW is never dropped |
| Video | same edited/original rule as photos |

Adjustment blobs and proxies are skipped.

### Burst frames

A burst appears in Photos — and in this app's grid — as a **single representative**.
PhotoKit withholds the remaining frames unless explicitly asked for, so a naive backup
silently drops them. Measured on a real library: 35,815 assets visible, **35,879 with
every burst frame**.

Downloads cover **every frame**. The grid still shows one tile per burst, matching
Photos, so the item count in the status line can exceed the number of tiles — that
difference is the extra frames.

### Finder tags

**On by default.** Every file is tagged with each album it belongs to, and favourites
get a `Favorite` tag. Date foldering means an album's photos end up scattered across
date directories, so the tags are what let you still ask Finder for "everything in
Summer Trip".

Album membership is built by walking each album once — around 60 fetches rather than
tens of thousands of per-asset queries.

Tags are stored in the `com.apple.metadata:_kMDItemUserTags` extended attribute. Local
APFS/HFS+ disks handle them natively and most SMB shares do as well, though some store
them in AppleDouble `._` sidecars and others reject them outright. **A tag that will not
stick never fails a download** — you just get the file without tags.

### Date-prefixed filenames

Optional, off by default. Roughly **8% of a real library** comes back from PhotoKit
named like `488ECD3E-3C17-467B-B85B-FAFE7461DEE8.mp4` — mostly saved videos. Turn this
on and files are written as `2024-03-15 488ECD3E….mp4`, which sorts and reads properly.
A filename that already begins with its own date is not stamped twice.

### File dates match when the photo was taken

Each downloaded file's creation and modification dates are set from the asset's capture
date. Without this a 2020 photo arrives stamped with today's date, which matters because
Finder sorting and NAS photo indexers (Synology Photos, Immich, PhotoPrism) commonly key
off file mtime — an otherwise correct backup would sort into nonsense.

### Why "Keep pre-edit originals" exists

Editing in Photos is **non-destructive**: iCloud keeps the untouched original *and* the
edited render as separate files, plus a recipe of the edits. PhotoKit exposes all three
(`.photo`, `.fullSizePhoto`, `.adjustmentData`). So yes — iCloud really does hold
multiple versions of the same photo.

By default the app saves the **edited** version, because that is the photo you see in
Photos and expect in a backup. Turn the toggle on to also keep the untouched original,
saved alongside as `IMG_1234_original.HEIC`. For an unedited photo there is only one
file and the toggle changes nothing — it never writes a pointless duplicate.

## Only downloading what's new

Pick a destination and the app scans it, then tells you what's actually missing —
*before* you download: **"1,247 new · 34,567 already downloaded"**. **Only new** is on
by default, so the Download button reads `Download 1,247 New` and fetches just those.

### How it decides, and why there's an index file

The **filesystem is the source of truth.** Alongside it, the app keeps an append-only
index at the destination root:

```
.icloudgui-index.tsv     <asset identifier>  <TAB>  <relative path>
```

That file answers exactly one question filenames cannot: **which photo produced which
file.** It matters because two photos from different devices can both be
`IMG_0001.HEIC`, and taken on the same day they land in the same folder. Matching on
filename alone, the second one looks already-downloaded and gets **silently skipped** —
a photo missing from your backup while the app reports success. The index makes each
photo's identity explicit, so the second is stored as `IMG_0001 (2).HEIC` and correctly
recognised on later runs.

**It is a cache, not a database, and you are not locked in:**

- Delete it and the tool still works — it falls back to filename matching (with the
  collision caveat above). It rebuilds as you download.
- It never overrides the filesystem. Delete a photo from the NAS and its row is pruned
  on the next scan, so the photo is fetched again.
- Your photos are plain files in plain date folders. Nothing needs this app to read them.
- It's tab-separated text: `grep` it, diff it, delete it.

Because it lives at the destination, a NAS shared between two Macs stays consistent.

### On a NAS specifically

The app does **one bulk directory scan** rather than checking each expected file. Over
SMB, 40,000 individual existence checks is 40,000 network round trips; one enumeration
is a handful of directory reads. Already-downloaded photos are then settled from the
index without touching PhotoKit at all.

## The library stays live

The app watches your photo library, so photos that arrive while it is open show up on
their own — no reopening, no refresh button needed. Your **selection survives** a
refresh: entries are held by identifier, and only photos that genuinely went away are
dropped. The status line notes how many arrived since you opened the window.

Album counts are recounted too, debounced by two seconds so an import firing a burst of
changes does not recount sixty albums each time.

The refresh button beside the destination forces a full reload of both the library and
the destination scan.

### Downloading new photos automatically

Off by default. In **File Options → Download new photos automatically**: every photo
that arrives is fetched as soon as it appears.

**Turn this on only after a full backup has finished.** Before that, the first change
triggers a download of everything still missing — which can be hundreds of gigabytes.

If an item fails repeatedly it is not retried in a loop: the app remembers the set it
last auto-started on and will not restart on the same one.

## Browsing by date

The grid is grouped by date with **sticky headers**, switchable between **Day / Month /
Year**, and sortable newest- or oldest-first. Each header has a **Select** button to
take or clear that whole day, month, or year at once.

## Before a full backup: check you have room

A full library is bigger than people expect. Sampling ~900 assets from a real 35,816-item
library gave a mean of **5.8 MB per item** (photos 4.5 MB, videos 26.4 MB) — about
**204 GB** in total.

The bar shows free space on the destination volume next to the path, turning **orange
below 25 GB**. That figure is macOS's "available for important usage", which counts
purgeable caches, so it reads higher than `df`. Treat it as an optimistic ceiling.

If the total does not fit, point the destination at your NAS rather than the home folder.
Running out mid-run is not destructive — completed files stay valid and **Only new**
picks up exactly where it stopped — but it wastes hours.

## The Mac stays awake while downloading

A 200 GB run takes hours, and idle sleep would stall every transfer. The app holds an
activity assertion for the duration of a download and releases it when finished.

**Closing the lid still sleeps the machine** — that is not something an app can override.
Leave the lid open, or set Energy Saver to prevent sleep, for an overnight run.

## Re-running is safe

Downloads stream to a `.part` file and are renamed only on success, so an interrupted
run never leaves a truncated photo behind. On a repeat run, files already present are
skipped — so you can re-run it as an incremental backup. Same-name items from different
devices or years get a ` (2)` suffix rather than overwriting.

Four downloads run in parallel; iCloud throttles harder than that.

## Layout

| File | Role |
|---|---|
| `ResourcePlan.swift` | Pure logic: resource selection, filenames, collisions |
| `Incremental.swift` | Destination scan, the index/ledger, new-vs-present analysis |
| `DateGrouping.swift` | Pure logic: date bucketing for the grid sections |
| `SelfCheck.swift` | Assertions for the above |
| `PhotoStore.swift` | Authorization, album/asset fetch, thumbnails |
| `Downloader.swift` | Streams originals to disk, bounded concurrency |
| `ContentView.swift` / `PhotoGrid.swift` | UI |
| `Guide.swift` | First-run intro and the reopenable user guide |
| `build.sh` | Assembles + signs the `.app` |
| `setup-signing.sh` | One-time local signing identity so Photos grants survive rebuilds |
