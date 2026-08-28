import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var store = PhotoStore()
    @StateObject private var downloader = Downloader()
    @StateObject private var dest = DestinationModel()

    @AppStorage("destinationPath") private var destinationPath = ""
    @AppStorage("includeOriginals") private var includeOriginals = false
    @AppStorage("onlyNew") private var onlyNew = true
    @AppStorage("folderLayout") private var layoutRaw = FolderLayout.dateFolders.rawValue
    @AppStorage("datePrefix") private var datePrefix = false
    @AppStorage("finderTags") private var writeFinderTags = true
    @AppStorage("autoDownload") private var autoDownload = false
    /// The set we last auto-started on, so a persistently failing item cannot put the
    /// app in a download loop.
    @State private var lastAutoAttempt: Set<String> = []
    @State private var showFailures = false
    @AppStorage("hasSeenGuide") private var hasSeenGuide = false
    @State private var showGuide = false

    var body: some View {
        Group {
            if store.isAuthorized {
                library
            } else {
                PermissionView(status: store.status) { await store.requestAccess() }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .task {
            if store.isAuthorized { store.loadAlbums() }
            if !destinationPath.isEmpty { dest.url = URL(fileURLWithPath: destinationPath) }
            refresh()
            if !hasSeenGuide { showGuide = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGuide)) { _ in
            showGuide = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAlbumForShot)) { note in
            guard let name = note.object as? String else { return }
            // Exact match first, so "Panoramas" cannot land on some other album that
            // merely contains the text; fall back to a substring match.
            let album = store.albums.first { $0.title.compare(name, options: .caseInsensitive) == .orderedSame }
                ?? store.albums.first { $0.title.localizedCaseInsensitiveContains(name) }
            let report = album.map { "matched: \($0.title) (\($0.count))" }
                ?? "NO MATCH for \(name); available: \(store.albums.map(\.title).joined(separator: ", "))"
            try? report.write(to: URL(fileURLWithPath: "/tmp/icg-album-match.txt"),
                              atomically: true, encoding: .utf8)
            if let album { store.select(album) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .setGroupingForShot)) { note in
            guard let raw = note.object as? String,
                  let g = DateGrouping(rawValue: raw) else { return }
            store.grouping = g
        }
        .sheet(isPresented: $showGuide) {
            GuideSheet(isFirstRun: !hasSeenGuide) {
                hasSeenGuide = true
                showGuide = false
            }
        }
        .onChange(of: store.selectedAlbum) { _, _ in refresh() }
        .onChange(of: includeOriginals) { _, _ in refresh() }
        .onChange(of: layoutRaw) { _, _ in refresh() }
        // The library changed underneath us, so what is "already downloaded" moved.
        .onChange(of: store.libraryVersion) { _, _ in refresh() }
        .onChange(of: dest.newAssetIDs) { _, ids in maybeAutoDownload(ids) }
        .onChange(of: datePrefix) { _, _ in refresh() }
    }

    private var layout: FolderLayout { FolderLayout(rawValue: layoutRaw) ?? .dateFolders }

    private func startDownload() {
        guard let root = dest.url else { return }
        downloader.start(assets: downloadTargets,
                         destination: root,
                         existing: dest.existing,
                         includeUnmodifiedOriginals: includeOriginals,
                         layout: layout,
                         datePrefix: datePrefix,
                         writeFinderTags: writeFinderTags)
    }

    /// Above this, an automatic run is a backup rather than a top-up, and wants a
    /// deliberate click. Without the cap, enabling auto-download before a first full
    /// backup would silently begin transferring an entire library — hundreds of
    /// gigabytes, unattended, with no one watching the free space.
    private static let autoDownloadLimit = 200

    /// Starts a download when new photos land, if the user asked for that.
    private func maybeAutoDownload(_ ids: Set<String>) {
        guard autoDownload, !ids.isEmpty, dest.url != nil,
              !downloader.progress.isRunning, !dest.isWorking,
              ids != lastAutoAttempt else { return }
        lastAutoAttempt = ids
        guard downloadTargets.count <= Self.autoDownloadLimit else { return }
        startDownload()
    }

    /// Shown when auto-download declined to start because the batch was too large.
    private var autoDownloadHeldBack: Bool {
        autoDownload && dest.plan != nil && !downloadTargets.isEmpty
            && downloadTargets.count > Self.autoDownloadLimit
            && !downloader.progress.isRunning
    }

    private func refresh() {
        guard dest.url != nil, !store.downloadableAssets.isEmpty else { return }
        // Pointless to rescan a folder we are actively writing into, and a finished
        // run already refreshes. New arrivals mid-download are picked up then.
        guard !downloader.progress.isRunning else { return }
        dest.refresh(assets: store.downloadableAssets,
                     includeUnmodifiedOriginals: includeOriginals,
                     layout: layout,
                     datePrefix: datePrefix)
    }

    private var library: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { store.selectedAlbum },
                set: { store.select($0) }
            )) {
                ForEach(store.albumGroups) { group in
                    Section(group.title) {
                        ForEach(group.albums) { album in
                            Label {
                                HStack {
                                    Text(album.title).lineLimit(1)
                                    Spacer()
                                    // A dash, not "0": these are unreadable, not empty.
                                    Text(album.notice == nil ? "\(album.count)" : "—")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            } icon: {
                                Image(systemName: album.symbol)
                                    .foregroundStyle(album.notice == nil
                                                     ? AnyShapeStyle(.primary)
                                                     : AnyShapeStyle(.secondary))
                            }
                            .tag(album)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                PhotoGrid(store: store)
                Divider()
                controls
            }
        }
    }

    /// What Download will actually fetch, after the album/selection and the "new only" filter.
    private var downloadTargets: [PHAsset] {
        let pool = store.effectiveAssets
        guard onlyNew, dest.plan != nil else { return pool }
        return pool.filter { dest.newAssetIDs.contains($0.localIdentifier) }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Destination gets a row to itself. Sharing one with the options squeezed
            // the path into an unreadable "...ents/Photos_Download".
            HStack(spacing: 10) {
                Button { chooseDestination() } label: {
                    Label("Destination", systemImage: "folder")
                }

                if let root = dest.url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    } label: {
                        Text(abbreviate(root.path))
                            .font(.callout)
                            .lineLimit(1)
                            // Middle keeps both the root and the folder name visible.
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("\(root.path)\n\nClick to reveal in Finder")

                    if let free = availableBytes(at: root) {
                        Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                             + " free")
                            .font(.callout)
                            // Under 25 GB will not hold a typical library.
                            .foregroundStyle(free < 25_000_000_000 ? .orange : .secondary)
                            .help("Space left on this volume. A full photo library commonly runs to several hundred gigabytes.")
                            .fixedSize()
                    }

                    Button {
                        store.loadAlbums()
                        store.select(store.selectedAlbum)
                        refresh()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload the library and re-scan the destination")
                        .disabled(dest.isWorking)
                } else {
                    Text("No folder chosen")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Open the guide (⌘?)")
            }

            HStack(spacing: 12) {
                Menu {
                    Picker("Organise into", selection: $layoutRaw) {
                        ForEach(FolderLayout.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Toggle("Date-prefix filenames", isOn: $datePrefix)
                    Toggle("Keep pre-edit originals", isOn: $includeOriginals)
                    Toggle("Write Finder tags", isOn: $writeFinderTags)

                    Divider()

                    Toggle("Download new photos automatically", isOn: $autoDownload)
                } label: {
                    Label("File Options", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(optionsSummary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)

                Spacer()

                Toggle("Only new", isOn: $onlyNew)
                    .toggleStyle(.checkbox)
                    .help("Skip anything already present in the destination folder.")
                    .disabled(dest.plan == nil)
            }

            // Shared albums hold Apple's downscaled copies, not the originals. Measured
            // on a real library: shared assets cap around 2048px (video 720p) while the
            // same library's own photos are 4284x5712.
            if store.selectedAlbum?.isShared == true {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Shared albums store reduced-size copies (about 2048px, video 720p). These are not full-resolution originals.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }

            if dest.url != nil {
                HStack(spacing: 8) {
                    if dest.isWorking {
                        ProgressView().controlSize(.small)
                    } else if let plan = dest.plan {
                        Image(systemName: plan.isEmpty
                              ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(plan.isEmpty ? .green : .accentColor)
                    }
                    Text(dest.statusText).font(.callout)
                        .foregroundStyle(dest.isWorking ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.tail)
                    if autoDownloadHeldBack {
                        Text("· too many for an automatic run, click Download")
                            .font(.callout).foregroundStyle(.orange).lineLimit(1)
                    }
                    if store.arrivedSinceOpen > 0 {
                        Text("· \(store.arrivedSinceOpen) arrived since opening")
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Button("Select All") { store.selectAll() }.disabled(store.assets.isEmpty)
                Button("Select None") { store.selectNone() }.disabled(store.selection.isEmpty)
                Text(selectionSummary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)

                Spacer()

                if downloader.progress.isRunning {
                    ProgressView(value: Double(downloader.progress.completed),
                                 total: Double(max(downloader.progress.total, 1)))
                        .frame(width: 160)
                    Text("\(downloader.progress.completed)/\(downloader.progress.total)")
                        .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { downloader.cancel() }
                } else {
                    Button { startDownload() } label: {
                        Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(dest.url == nil || downloadTargets.isEmpty || dest.isWorking)
                }
            }

            if downloader.progress.isRunning, !downloader.progress.currentFile.isEmpty {
                HStack(spacing: 8) {
                    Text(downloader.progress.currentFile)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    // Large videos otherwise sit at one item with no movement for
                    // minutes; this is the only sign the transfer is alive.
                    if let fraction = downloader.progress.currentFileFraction {
                        ProgressView(value: fraction).frame(width: 110).controlSize(.small)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if let message = downloader.progress.finishedMessage, !downloader.progress.isRunning {
                HStack {
                    Text(message).font(.callout)
                    if !downloader.failures.isEmpty {
                        Button("Show errors") { showFailures = true }.buttonStyle(.link)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .sheet(isPresented: $showFailures) {
            FailureList(failures: downloader.failures, logFolder: dest.url) {
                showFailures = false
            }
        }
        .onChange(of: downloader.progress.isRunning) { wasRunning, isRunning in
            // A finished run changes what the destination holds, so the counts are stale.
            if wasRunning, !isRunning { refresh() }
        }
    }

    /// Compact readout of what File Options is currently set to.
    private var optionsSummary: String {
        var parts = [layout.title]
        if datePrefix { parts.append("dated names") }
        if includeOriginals { parts.append("+ originals") }
        if writeFinderTags { parts.append("tags") }
        if autoDownload { parts.append("auto") }
        return parts.joined(separator: " · ")
    }

    private var downloadLabel: String {
        let n = downloadTargets.count
        if n == 0 { return onlyNew && dest.plan != nil ? "Nothing New" : "Download" }
        return onlyNew && dest.plan != nil ? "Download \(n) New" : "Download \(n)"
    }

    private var selectionSummary: String {
        if store.selection.isEmpty {
            return "Whole album in scope"
        }
        return "\(store.selection.count) selected"
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to save photos (a local folder or a mounted NAS share)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
        dest.url = url
        refresh()
    }
}

// MARK: - Permission gate

struct PermissionView: View {
    let status: PHAuthorizationStatus
    let request: () async -> Void
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 52)).foregroundStyle(.tint)
            Text("iCloud GUI needs access to your Photos library")
                .font(.title2).bold()
            Text("Your photos are read through macOS. No Apple ID password is ever requested or stored, and Advanced Data Protection can stay on.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)

            if status == .denied || status == .restricted {
                Text("Access was denied. Enable it in System Settings › Privacy & Security › Photos.")
                    .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Open Privacy Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
                    NSWorkspace.shared.open(url)
                }
            } else {
                Button {
                    requesting = true
                    Task { await request(); requesting = false }
                } label: {
                    Text("Grant Photos Access").frame(width: 180)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).disabled(requesting)
            }
        }
        .padding(40)
    }
}

// MARK: - Errors

struct FailureList: View {
    let failures: [DownloadFailure]
    var logFolder: URL?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(failures.count) item\(failures.count == 1 ? "" : "s") failed").font(.headline)
            Text("Also written to \(RunLog.filename) in the destination folder, so this list survives quitting.")
                .font(.callout).foregroundStyle(.secondary)
            List(failures) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.filename).font(.callout).bold()
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 460, minHeight: 260)
            HStack {
                if let logFolder {
                    Button("Show Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [logFolder.appendingPathComponent(RunLog.filename)])
                    }
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
