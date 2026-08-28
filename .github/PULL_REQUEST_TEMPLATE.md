## What this changes

<!-- One or two sentences. If it fixes an issue, link it. -->

## Checklist

- [ ] `./run.sh --self-check` passes
- [ ] Non-trivial logic has an assertion in `SelfCheck.swift`
- [ ] No new third-party dependencies
- [ ] Comments explain *why* for anything that looks surprising
- [ ] **Documentation updated in this PR** — README, CONTRIBUTING, RELEASING, SECURITY
      or the in-app guide in `Guide.swift`, whichever this change affects
- [ ] **Version bumped** in `build.sh` (`CFBundleShortVersionString` and
      `CFBundleVersion`) if anything under `Sources/` or `build.sh` changed, with a
      `CHANGELOG.md` entry. Tooling-only changes need neither.

## If this touches PhotoKit

Much of this app's behaviour is constrained by macOS in ways that look like bugs.
Before changing anything here, check the "Things worth knowing" section in
[CONTRIBUTING.md](../CONTRIBUTING.md) — Hidden, Recently Deleted, shared album
resolution, burst frames and hardened runtime have each already cost someone an
afternoon.

Say which macOS version you tested on, and paste relevant diagnostic output
(`--albums`, `--hidden`, `--extras`) if the change affects what the app can see.
