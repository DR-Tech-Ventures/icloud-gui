import SwiftUI

extension Notification.Name {
    /// Posted by the Help menu so the guide can be reopened at any time.
    static let showGuide = Notification.Name("com.local.icloudgui.showGuide")
}

private struct GuideItem: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let body: String
    var tone: Tone = .normal

    enum Tone { case normal, caution }
}

private struct GuideChapter: Identifiable {
    let id = UUID()
    let title: String
    let items: [GuideItem]
}

/// First-run introduction, and the permanent user guide. Same content either way --
/// an intro you can never see again is useless the moment you forget something.
struct GuideSheet: View {
    let isFirstRun: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(chapters) { chapter in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(chapter.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .kerning(0.6)
                            ForEach(chapter.items) { item in row(item) }
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 660)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(isFirstRun ? "Welcome to iCloud GUI" : "iCloud GUI Guide")
                    .font(.title2).bold()
                Text("Download your iCloud photos to this Mac or a NAS.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func row(_ item: GuideItem) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: item.symbol)
                .font(.system(size: 16))
                .foregroundStyle(item.tone == .caution ? AnyShapeStyle(.orange)
                                                       : AnyShapeStyle(Color.accentColor))
                .frame(width: 24, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout).bold()
                Text(item.body)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            if isFirstRun {
                Text("You can reopen this any time from the Help menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isFirstRun ? "Get Started" : "Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var chapters: [GuideChapter] {
        [
            GuideChapter(title: "How it works", items: [
                GuideItem(symbol: "lock.open",
                          title: "Your Apple ID password is never used",
                          body: "There is no login here. macOS is already signed into iCloud, so the app asks the system for access to your Photos library and reads it through Apple's own framework. Nothing is typed, stored, or sent anywhere."),
                GuideItem(symbol: "checkmark.shield",
                          title: "Advanced Data Protection can stay on",
                          body: "Two-factor authentication is a non-issue too. Tools that use the unofficial iCloud web API require you to disable Advanced Data Protection; this one does not."),
                GuideItem(symbol: "icloud.and.arrow.down",
                          title: "Full-resolution originals",
                          body: "Photos that live only in iCloud are pulled down on demand at full resolution — they do not need to be downloaded in the Photos app first."),
            ]),
            GuideChapter(title: "Downloading", items: [
                GuideItem(symbol: "sidebar.left",
                          title: "1 · Pick an album",
                          body: "The sidebar groups your Library, Smart Albums, My Albums, and Shared Albums. All Photos covers your whole library."),
                GuideItem(symbol: "checkmark.circle",
                          title: "2 · Choose photos, or don't",
                          body: "Click thumbnails to select. Each date header has a Select button to take that whole day, month, or year. Selecting nothing downloads the entire album — the text beside the buttons always says what is in scope."),
                GuideItem(symbol: "folder",
                          title: "3 · Set a destination",
                          body: "Any local folder, or a mounted NAS share. It is remembered between launches."),
                GuideItem(symbol: "externaldrive.badge.questionmark",
                          title: "Check you have room first",
                          body: "A full library is bigger than most people expect — a real 35,000-item library measured around 204 GB, averaging 5.8 MB per item. Free space on the destination is shown next to the folder, and turns orange below 25 GB. If it will not fit, point at a NAS instead of your home folder.\n\nRunning out mid-way is not destructive: finished files stay valid and Only new resumes exactly where it stopped."),
                GuideItem(symbol: "moon.zzz",
                          title: "Your Mac stays awake while downloading",
                          body: "A large backup runs for hours, so the app prevents idle sleep until it finishes. Closing the lid still sleeps the machine — no app can override that — so leave it open for an overnight run."),
                GuideItem(symbol: "arrow.down.circle.fill",
                          title: "4 · Download",
                          body: "Two progress bars: one for the whole run, and one for the file currently transferring — so a large video shows movement instead of appearing stuck. Cancel at any point; a half-written photo is never left behind."),
            ]),
            GuideChapter(title: "Options", items: [
                GuideItem(symbol: "antenna.radiowaves.left.and.right",
                          title: "The library updates itself",
                          body: "You do not need to reopen the app when new photos arrive. The grid follows your library live — take a photo on your phone and it appears here once iCloud syncs it, with your selection left intact. The status line notes how many arrived since you opened the window.\n\nThe refresh button next to the destination folder forces a full reload if you want one."),
                GuideItem(symbol: "arrow.trianglehead.2.clockwise",
                          title: "Download new photos automatically",
                          body: "Off by default. Turn it on and every photo that arrives is fetched as soon as it appears, with no clicking.\n\nTurn it on only after a full backup has finished. Doing it beforehand means the first change triggers a download of everything still missing, which can be hundreds of gigabytes."),
                GuideItem(symbol: "sparkles",
                          title: "Only new",
                          body: "On by default. The app scans your destination and tells you what is actually missing before you start — \"1,247 new · 34,567 already downloaded\". Re-run it any time as an incremental backup; nothing is fetched twice."),
                GuideItem(symbol: "calendar",
                          title: "Date folders or one folder",
                          body: "Save as 2024/2024-03-15/IMG_1234.HEIC, or drop everything straight into the destination. Switching affects new downloads only — files already saved stay where they are."),
                GuideItem(symbol: "square.on.square",
                          title: "Keep pre-edit originals",
                          body: "Editing in Photos is non-destructive: iCloud keeps both the untouched original and the edited version. By default you get the edited one. Turn this on to save both, with the original suffixed _original."),
                GuideItem(symbol: "textformat.123",
                          title: "Date-prefix filenames",
                          body: "Some photos and videos come out of iCloud named like 488ECD3E-3C17-467B-B85B-FAFE7461DEE8.mp4 — around 8% of a typical library. Turn this on and files are saved as 2024-03-15 488ECD3E….mp4 instead, so they sort and read properly. A name that already starts with its date is left alone."),
                GuideItem(symbol: "tag",
                          title: "Finder tags",
                          body: "On by default. Each file is tagged with every album it belongs to, and favourites get a Favorite tag — so you can still find \"everything from Summer Trip\" in Finder even though the files are filed by date. Tags live in an extended attribute: local disks handle them natively, and most NAS shares do too, but a share that rejects them just means no tags — your download is unaffected."),
                GuideItem(symbol: "livephoto",
                          title: "Live Photos and RAW are kept whole",
                          body: "A Live Photo saves the still and its .mov together. A RAW+JPEG pair saves both halves — the RAW is never silently dropped."),
            ]),
            GuideChapter(title: "Limits macOS imposes", items: [
                GuideItem(symbol: "eye.slash",
                          title: "Hidden photos may be withheld",
                          body: """
                          While your Hidden album requires Touch ID or a password, macOS hands nothing to any third-party app — not even one with full Photos access.

                          To get your hidden photos:
                          1.  Open Photos
                          2.  Settings (⌘,) → General
                          3.  Turn off “Use Touch ID or Password”
                          4.  Come back here and click the rescan button next to your destination folder
                          """,
                          tone: .caution),
                GuideItem(symbol: "trash.slash",
                          title: "Recently Deleted cannot be read",
                          body: """
                          Apple's framework has no Recently Deleted album at all, so no third-party app can reach it. This is a macOS restriction, not a missing feature here.

                          To get your deleted photos:
                          1.  Open Photos
                          2.  Go to Recently Deleted in the sidebar
                          3.  Select the photos you want and click Recover
                          4.  Come back here and click rescan — they are in your library again
                          """,
                          tone: .caution),
                GuideItem(symbol: "person.2",
                          title: "Shared albums are reduced size",
                          body: "iCloud stores about 2048px copies in Shared Albums (video at 720p), not originals. You can download them, but they are not a full-resolution backup. The full original lives in the library of whoever shared it.",
                          tone: .caution),
            ]),
        ]
    }
}
