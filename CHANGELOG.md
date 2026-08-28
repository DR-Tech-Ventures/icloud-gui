# Changelog

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
