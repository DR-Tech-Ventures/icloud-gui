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
