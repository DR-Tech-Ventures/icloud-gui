---
name: Bug report
about: Something is not working
---

**Before filing — these three are macOS restrictions, not bugs:**

- **Hidden album is empty.** macOS withholds hidden photos from every third-party app
  while the album requires Touch ID or a password. Turn that off in Photos → Settings →
  General, then rescan.
- **Recently Deleted has no photos.** Apple's framework has no such album. No
  third-party app can read it. Recover them in Photos first.
- **Shared album photos are low resolution.** iCloud stores ~2048px copies in Shared
  Albums (video 720p). The full original lives in the library of whoever shared it.

---

**What happened**

**What you expected**

**macOS version and Mac model**

**Diagnostic output**

Run whichever is relevant and paste the result:

```bash
open "build/iCloud GUI.app" --args --status && sleep 4 && cat /tmp/icloudgui-status.txt
open "build/iCloud GUI.app" --args --albums && sleep 8 && cat /tmp/icg-albums.txt
open "build/iCloud GUI.app" --args --hidden && sleep 8 && cat /tmp/icg-hidden.txt
```

**Does the self-check pass?**

```bash
./run.sh --self-check
```

**If the app quit or vanished on its own**

The app writes breadcrumbs to the macOS unified log. Paste the last hour:

```bash
log show --predicate 'subsystem == "com.drtechventures.icloudgui"' --last 1h --style compact
```

A `launched` line with no matching `terminating normally` means the process was killed
rather than quit — worth saying so, it narrows things down a lot.

If it actually crashed, macOS wrote a full report. Attach the newest one:

```bash
ls -t ~/Library/Logs/DiagnosticReports/ | grep -i iCloudGUI | head -3
```

**If a download failed**, the run log lives beside the photos, at
`.icloudgui-log.txt` in your destination folder.
