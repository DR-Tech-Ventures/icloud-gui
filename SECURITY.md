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
- **Makes no network requests of its own.** All iCloud traffic is PhotoKit's, inside
  Apple's frameworks.
- Has **no analytics, telemetry, or third-party dependencies.**

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
