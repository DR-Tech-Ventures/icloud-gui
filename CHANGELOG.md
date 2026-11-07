# Changelog

## 1.4.1

**"Check for Updates…" no longer tells Homebrew users to do the wrong thing.**

- **The update alert now covers both ways of installing.** It said to open the disk image
  and drag the app into place, which is right if that is how you installed it and wrong
  if you used `brew install --cask`: dragging a disk image over a Homebrew-managed copy
  leaves Homebrew still believing the old version is there, and `brew upgrade` will not
  put that right afterwards. The alert now gives the `brew upgrade` command first and the
  disk image instructions after it.

  It does not try to detect which applies. Homebrew moves the app into `/Applications`
  rather than symlinking it, so a brew-installed copy looks identical from the inside;
  telling them apart would mean hunting for a Caskroom beside a guessed prefix, and
  guessing wrong would land right back on confident advice that breaks someone's install.

## 1.4

**Requires macOS 27. The app now tells you how big a download is before it starts.**

- **macOS 27 is the minimum.** 1.3.x ran on macOS 26. If you are on Tahoe, stay on 1.3.2 —
  it is complete and does everything this release does except show download sizes.
- **The destination line now says how much there is to fetch**, not just how many files:
  "1,240 new (1,312 files, 8.4 GB)". That comes from `PHAssetResource.dataSize`, which is
  new in macOS 27 and is the whole reason for the version bump.
- **It warns when the download will not fit**, instead of guessing from a fixed
  threshold. The free-space figure turns red and says "not enough" when what is still to
  download is larger than the space left. Previously it went orange under 25 GB, which is
  ample for a 3 GB run and hopeless for a 200 GB one.
- **Unknown sizes are reported as unknown.** PhotoKit only knows a resource's size once
  it is local, so for an iCloud-only library many sizes come back nil — which is the
  common case here, not the exception. Those are counted separately and the total reads
  "at least 8.4 GB" rather than pretending to be complete. The app never claims a run
  *will* fit: with sizes missing that is not something it can know, and for a backup tool
  guessing in the reassuring direction is the failure that actually costs you photos.
- **`PHAssetResource.originalFilename` is deprecated in macOS 27**, so filenames now come
  from `filename`. That property is optional where the old one was not, and the fallback
  is deliberately the deprecated property rather than a name of our own: the download
  ledger keys on the path it wrote, so a photo whose name changed between versions would
  read as missing and be downloaded a second time. Every file already on disk stays
  recognisable.
- **CI now builds against the same SDK as releases.** It ran on the `macos-26` image,
  which carries Xcode 26.6 and so compiled against the macOS 26 SDK, while releases were
  built against 27. The step that checks the stamped SDK could never have caught that — it
  compares the binary against whatever SDK the machine running it has, so it passed on
  both while the two disagreed.

## 1.3.2

**Hardening, from an audit that found no vulnerabilities.** Nothing here fixes a bug you
could hit. Three places were doing more than they needed to, and all three are cheaper to
narrow now than to explain later.

- **"Check for Updates…" now refuses a release page that is not on GitHub.** The URL it
  opens came out of the JSON reply and went straight to `NSWorkspace.shared.open`, which
  hands whatever it is given to LaunchServices — a `file:///` path or a registered app
  scheme included. It took breaking TLS to put a hostile value there, so this was never
  a live hole; but the scheme and host are now checked instead of assumed, and a reply
  that names anywhere else is reported as not having come from GitHub. The self-check
  covers the lookalike cases (`github.com.evil.example`, `github.com` in the path).
- **CI states its own token permissions.** The repository default is already read-only,
  but that is a setting in the web UI rather than a line in the workflow, so flipping it
  would quietly widen every job at once. `permissions: contents: read` now lives in
  `ci.yml`, where a change to it appears in a diff. The checkout also runs with
  `persist-credentials: false`: nothing after it uses git, and the default left the token
  sitting in `.git/config` for the rest of the job.
- **`setup-signing.sh` no longer imports the local signing key with `-A`.** That flag lets
  any application use the key without prompting, which made the `-T /usr/bin/codesign`
  next to it meaningless. codesign is the only thing that ever needs it. The certificate
  is self-signed and local, so nothing signed with it was ever distributable — the key
  simply had wider reach than the one tool that uses it. Builds are unaffected.

## 1.3.1

**The toolbar stops shifting when you change album.**

- **The toolbar no longer slides sideways with the album name.** A unified toolbar lays
  its items out after the window title, so the grouping picker and the sort button sat a
  different distance from the left edge for every album — "Recents" and "Recently Added"
  moved the whole row by the width of eight characters. The controls are now anchored to
  the trailing edge by a single flexible `ToolbarSpacer`, and the title grows into the
  empty space beside them instead of pushing them.
- **The download button keeps one width.** Its label carries a count, and the count
  arrives a moment after the album does because the fetch runs off the main actor — so
  the button resized itself just after every album change, dragging the three controls
  to its left along with it. It is now fixed at the width of a six-figure count.
- **The subtitle is never blank.** An empty subtitle makes macOS draw the title as a
  single centred line rather than a stacked title and subtitle, so selecting Hidden or
  Recently Deleted changed the size and baseline of the album name. Those albums now say
  "Unavailable to other apps" and the title stays put.

## 1.3

**Requires macOS 26. The app icon is now layered and drawn by the system.**

- **macOS 26 is the minimum.** 1.2 ran on macOS 14 and later. If you are on Sonoma or
  Sequoia, stay on 1.2 — it is complete and still works. Everything the app does that
  people care about, it already did there.
- **Swift 6 language mode**, with compile-time data-race checking on. Three pieces of
  shared mutable state that the compiler could not prove safe are gone rather than
  annotated away: the demo flag is read from the arguments instead of assigned at launch,
  the run log builds its date formatter per call instead of sharing one, and the probe's
  log is a locked type instead of a captured local — that last one was a real data race
  that happened not to fire.
- **The toolbar's two halves are now separate Liquid Glass groups**, via `ToolbarSpacer`.
  It needs the macOS 26 SDK, which is why 1.2 left it out.
- **The window appears about three times sooner** — 1.5 seconds to 0.47 on a
  35,000-asset library. Every PhotoKit query now runs off the main actor: enumerating
  the 77 albums, fetching the assets, and rebuilding after a library change. Previously
  all of it ran on the main actor inside the first render, so the window itself could not
  draw until the library had finished loading. Main-actor work at launch went from about
  800ms to about 70ms.
- **The grid no longer stutters while a download runs.** Every library change rebuilt all
  35,000 assets on the main actor, and a download makes the library change constantly.
  That rebuild moved off the main actor too.
- **Finder tags use `URLResourceValues.tagNames`** instead of hand-writing a property
  list into the extended attribute with `setxattr`. The setter needs macOS 26, which is
  now the deployment target. The attribute written is identical, which the self-check
  confirms by reading it back both ways.
- **Timings are in the log.** `loadAlbums.enumerate`, `select.fetch`,
  `select.rebuildSections`, `change.rematerialise` and time-to-window are recorded on
  every launch, so "it feels slow" can be answered from a bug report rather than a
  special build.
- **Layered app icon.** `Icon/AppIcon.icon` carries a gradient fill and a single glyph
  layer -- no container, no shadow, no specular highlight. On macOS 26 the system draws
  all three itself, and differently per appearance (default, dark, clear, tinted), so the
  glyph picks up real edge lighting and depth instead of the flat bitmap 1.2 shipped.
  `build.sh` compiles it with `actool` into `Assets.car`.
  The hand-rendered `AppIcon.icns` still ships beside it as the fallback for a build
  without Xcode -- it is drawn per size from 16 to 1024, where `actool`'s own generated
  fallback stops at 256.
- **Building still does not require Xcode.** `actool` ships inside `Xcode.app` and not in
  the Command Line Tools, so the layered icon is compiled only when it is available.
  Without it the build says so and ships the `.icns` alone. CI has Xcode and now asserts
  the layered icon was produced, because skipping it silently is the failure worth
  catching.
- `Icon/Layers/` is gone, replaced by the real `Icon/AppIcon.icon` document. 1.2 shipped
  those two PNGs as a hand-off to Icon Composer; the format turned out to be plain JSON
  beside a PNG, so the hand-off is not needed and the icon is fully scripted.

**Fixes**

- **`--shot` waited a fixed nine seconds for the window and gave up if it was not there.**
  When launch got slower than that guess it exited with code 3 and no file, which is a
  miserable thing to diagnose from a missing screenshot. It now waits for the window to
  appear, and applies `--album` and `--group` once the window is up rather than on a
  separate timer that could lose the race and capture the wrong grouping.
- **A library change could cancel the album recount it had just scheduled.** The debounce
  and the enumeration shared one task handle, so the reload cancelled the task it was
  running inside.

## 1.2

**The interface has been rebuilt around the window toolbar, and the app now adopts the
Liquid Glass design on macOS 26 and later.**

- **Liquid Glass.** The app was compiling against the current SDK but telling macOS it
  was not: SwiftPM stamps the binary's recorded SDK version from the deployment target,
  so the linked-on-or-after check that gates the new design saw 14.0 and served the old
  appearance. The build now stamps the real SDK version while the deployment target
  stays at macOS 14, so nothing is dropped — macOS 14 through 25 look exactly as before.
- **Controls moved into the toolbar.** The title bar was empty while four rows of
  controls were stacked under the grid. Grouping, sort order, thumbnail size, the
  destination, File Options and Download are now in the window toolbar, and what is left
  below the grid is a single status line.
- **The window has a title again** — the selected album and its item count, so the app
  names itself properly in Mission Control and the Window menu.
- **Filter the sidebar.** A search field above the album list, which matters once a
  library has more albums than fit on screen.
- **One destination menu** replaces the separate Destination button, path button and
  rescan button: choose the folder, reveal it in Finder, or reload and rescan.
- **Only new** is now **Only download what is missing**, in File Options. The Download
  button already said `Download 1,247 New` when it was on, so the separate checkbox was
  repeating it.
- **Check for Updates…**, in the iCloud GUI menu. It asks GitHub for the latest release
  tag and offers to open the release page. Deliberately manual: a background updater
  would tell a server this Mac is running the app every few hours, which would make the
  app's own privacy claim untrue. It does not install anything either — replacing a
  running bundle changes the code signature macOS ties the Photos grant to.
- **Releases ship as a disk image** instead of a zip, with an `/Applications` shortcut
  to drag onto. Running the app out of `~/Downloads` is how people end up re-granting
  Photos access every time it moves.
- **The window opens wide enough to use.** It now opens at 1280×840 and will not go
  below 1180 wide — narrower than that and macOS folded the toolbar's trailing items,
  Download included, into a "»" overflow menu.
- Thumbnail size is remembered between launches, and its slider moved to the bar under
  the grid where there is room for it.
- Item counts in the status line are written with thousands separators, matching the
  sidebar and the counts the guide quotes.

**Fixes**

- **`./run.sh` could silently run the previous build.** `build.sh` deletes the app bundle
  before reassembling it, but a running instance survives that — macOS keeps the inode
  alive while the process holds it — and `open` then *activates that stale process*
  rather than launching what was just built. Same pid, old binary, old arguments, running
  against a bundle whose resources no longer exist, which is why it would later vanish
  with no crash report. `build.sh` now quits an instance running from its own bundle
  first, targeted by path so a copy in `/Applications` is left alone.
- **Lifecycle breadcrumbs in the macOS unified log** (`log show --predicate 'subsystem ==
  "com.drtechventures.icloudgui"'`). Launch, Photos authorisation, album loads, and
  orderly termination. A `launched` line with no `terminating normally` after it is how
  you tell "killed" from "quit" — a distinction no crash report can make, because being
  killed is not a crash.

## 1.1

**A record of every run is now kept at the destination.**

- **Run log** (`.icloudgui-log.txt`) — one line per run start, per failure and per run
  end, written unbuffered so a crash cannot take it with it. Failures record the
  filename, the asset identifier and the reason, so a photo that did not make it can be
  traced back. Previously failures lived only in memory and vanished when the app quit,
  which for a backup tool loses the half that matters.
- Finder tag writes are now reported rather than swallowed, so a share that rejects
  extended attributes shows up in the log instead of quietly producing untagged files.

**Fixes**

- **Automatic downloads are capped at 200 items.** Enabling auto-download before a first
  full backup would previously begin transferring an entire library unattended —
  hundreds of gigabytes, with nothing watching free space. Larger batches now wait for a
  click.
- Hidden and Recently Deleted moved from Library to a new **Utilities** section at the
  bottom of the sidebar. Both usually read "—" because macOS withholds them, and sitting
  directly under All Photos made the first three rows look broken.
- `--album` and `--group` now work without `--shot`; they were parsed inside the
  screenshot path and silently did nothing on their own.

## 1.0

First release. Browse an iCloud Photos library and download full-resolution originals to
a Mac or a NAS, using Apple's PhotoKit — no Apple ID password, and Advanced Data
Protection can stay enabled.
