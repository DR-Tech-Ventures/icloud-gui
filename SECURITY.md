# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Email **admin@drtechventures.com** with:

- What the issue is and how to reproduce it
- The macOS version and app version (`CFBundleShortVersionString` in the app's Info.plist)
- Anything you know about impact

You should get an acknowledgement within a few days.

## What this app can reach

Worth knowing when judging whether something is a security issue. The app:

- **Reads** your Photos library through Apple's PhotoKit framework, under a permission
  macOS grants explicitly. It never writes to the library.
- **Writes** downloaded files, plus an index file (`.icloudgui-index.tsv`), to the
  destination folder you pick.
- **Never asks for, receives, stores, or transmits your Apple ID password.** There is no
  login in this app. Authentication is entirely macOS's, and no credential ever passes
  through this code.
- **Makes exactly one network request of its own, and only when you ask for it.**
  Choosing **iCloud GUI ▸ Check for Updates…** fetches the latest release tag from
  `api.github.com` and compares it with the running version. Nothing about you or your
  library is sent, nothing is downloaded or installed, and the request is never made on
  a timer or at launch. Never using that menu item means the app makes no requests of
  its own at all. All other iCloud traffic is PhotoKit's, inside Apple's frameworks.
- Has **no analytics, telemetry, crash reporting, or third-party dependencies.** There
  is deliberately no Sentry-style reporter: crash payloads from this app would carry file
  paths, which here means album names, photo filenames and your home directory. macOS
  already writes native crash reports locally, to `~/Library/Logs/DiagnosticReports/`,
  and you choose whether to attach one to a bug report.
- Writes **lifecycle breadcrumbs to the macOS unified log** (launch, authorisation
  result, album counts, termination). That log is local to your Mac and is never sent
  anywhere; interpolated values are redacted unless explicitly marked public, and none of
  the public ones carry paths or album names.

Given that, the security surface worth reporting is roughly:

- Anything causing files to be written outside the chosen destination (path traversal —
  filenames are sanitised in `ResourcePlan.swift`, and the self-check covers it)
- Anything that could expose library contents beyond the destination folder
- Anything that could cause silent data loss in a backup, such as a photo reported as
  downloaded when it was not

That last one is treated as seriously as a conventional vulnerability. A backup tool
that quietly loses photos while reporting success is the worst failure this app has.

## Verifying a release

Releases are signed with a Developer ID certificate and notarised by Apple. Check any
download before trusting it:

```bash
spctl -a -vvv "iCloud GUI.app"
```

Expected:

```
accepted
source=Notarized Developer ID
origin=Developer ID Application: DR Tech Ventures LLC (DJ2RANBKU3)
```

Anything else means the app has been altered since it was signed. Do not run it.
