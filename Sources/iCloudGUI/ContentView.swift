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
    @AppStorage("thumbSize") private var thumbSize = 132.0
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
        .frame(minWidth: 1180, minHeight: 700)
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
                ForEach(store.visibleGroups) { group in
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
            .searchable(text: $store.albumFilter, placement: .sidebar, prompt: "Filter albums")
        } detail: {
            VStack(spacing: 0) {
                PhotoGrid(store: store, thumbSize: $thumbSize)
                Divider()
                statusBar
            }
            // Fills what was an empty title bar, and makes the window name itself in
            // Mission Control and the window menu.
            .navigationTitle(store.selectedAlbum?.title ?? "iCloud GUI")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
        }
    }

    private var subtitle: String {
        guard let album = store.selectedAlbum, album.notice == nil else { return "" }
        let n = album.count
        return "\(n.formatted()) item\(n == 1 ? "" : "s")"
    }

    /// What Download will actually fetch, after the album/selection and the "new only" filter.
    private var downloadTargets: [PHAsset] {
        let pool = store.effectiveAssets
        guard onlyNew, dest.plan != nil else { return pool }
        return pool.filter { dest.newAssetIDs.contains($0.localIdentifier) }
    }

    // MARK: - Window toolbar

    /// Grouping and sort order first, then the destination and the download action.
    /// Before this they were four stacked rows under the grid while the title bar sat
    /// empty. Kept deliberately short: every item added here is one the toolbar can
    /// decide to hide behind "»" at the minimum window width, and Download must never
    /// be the item it picks.
    ///
    /// Deliberately no ToolbarSpacer between the two halves: it needs the macOS 26 SDK
    /// to compile, which would stop the project building on the macOS 15 runner CI uses
    /// and on any contributor's Mac without Tahoe -- and SwiftUI groups these items into
    /// the same Liquid Glass clusters without it. Nothing here is macOS 26-only; the
    /// glass comes from the SDK version build.sh stamps, not from source.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("", selection: $store.grouping) {
                ForEach(DateGrouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .help("Group the grid by day, month, or year")
        }
        ToolbarItem {
            Button {
                store.newestFirst.toggle()
            } label: {
                Label(store.newestFirst ? "Newest first" : "Oldest first",
                      systemImage: store.newestFirst ? "arrow.down" : "arrow.up")
            }
            .help("Flip the sort order")
        }
        ToolbarItem { destinationMenu }
        ToolbarItem { fileOptionsMenu }
        ToolbarItem {
            Button { showGuide = true } label: {
                Label("Guide", systemImage: "questionmark.circle")
            }
            .help("Open the guide (⌘?)")
        }
        ToolbarItem {
            if downloader.progress.isRunning {
                Button("Cancel", role: .cancel) { downloader.cancel() }
            } else {
                Button { startDownload() } label: {
                    Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(dest.url == nil || downloadTargets.isEmpty || dest.isWorking)
            }
        }
    }

    /// One control for the destination folder, replacing what were three: a Destination
    /// button, the path as a second button, and a separate rescan button.
    private var destinationMenu: some View {
        Menu {
            Button("Choose Destination…") { chooseDestination() }
            if let root = dest.url {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
                Divider()
                Button("Reload Library and Rescan") {
                    store.loadAlbums()
                    store.select(store.selectedAlbum)
                    refresh()
                }
                .disabled(dest.isWorking)
            }
        } label: {
            Label(dest.url?.lastPathComponent ?? "Destination", systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
        }
        .help(dest.url.map { "Saving to \(abbreviate($0.path))" } ?? "Choose where to save")
    }

    private var fileOptionsMenu: some View {
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

            // Was a checkbox of its own in the old bottom panel. The Download button
            // already says "Download 1,247 New" when it is on, so the visible control
            // was repeating what the button said.
            Toggle("Only download what is missing", isOn: $onlyNew)
                .disabled(dest.plan == nil)
            Toggle("Download new photos automatically", isOn: $autoDownload)
        } label: {
            Label("File Options", systemImage: "slider.horizontal.3")
        }
        .help(optionsSummary)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Select All") { store.selectAll() }.disabled(store.assets.isEmpty)
                Button("Select None") { store.selectNone() }.disabled(store.selection.isEmpty)
                Text(selectionSummary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)

                Spacer(minLength: 12)

                if dest.url == nil {
                    Text("No destination folder chosen")
                        .font(.callout).foregroundStyle(.secondary).fixedSize()
                } else {
                    destinationStatus
                }

                // Lives here rather than in the toolbar: at the minimum window width
                // the toolbar was overflowing its trailing items -- Download included --
                // into the "»" menu, and this is the one view control that is set once
                // and left alone. The status bar has the room.
                Divider().frame(height: 16)
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $thumbSize, in: 84...220).frame(width: 90)
                Image(systemName: "photo.fill").font(.body).foregroundStyle(.secondary)
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

            if downloader.progress.isRunning {
                HStack(spacing: 8) {
                    ProgressView(value: Double(downloader.progress.completed),
                                 total: Double(max(downloader.progress.total, 1)))
                        .frame(width: 160)
                    Text("\(downloader.progress.completed)/\(downloader.progress.total)")
                        .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    if !downloader.progress.currentFile.isEmpty {
                        Text(downloader.progress.currentFile)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        // Large videos otherwise sit at one item with no movement for
                        // minutes; this is the only sign the transfer is alive.
                        if let fraction = downloader.progress.currentFileFraction {
                            ProgressView(value: fraction).frame(width: 90).controlSize(.small)
                            Text("\(Int(fraction * 100))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } else if let message = downloader.progress.finishedMessage {
                HStack {
                    Text(message).font(.callout)
                    if !downloader.failures.isEmpty {
                        Button("Show errors") { showFailures = true }.buttonStyle(.link)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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

    /// What is missing at the destination, and whether it will fit.
    @ViewBuilder
    private var destinationStatus: some View {
        if dest.isWorking {
            ProgressView().controlSize(.small)
        } else if let plan = dest.plan {
            Image(systemName: plan.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle")
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
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        if let root = dest.url, let free = availableBytes(at: root) {
            Text("· " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                 + " free")
                .font(.callout)
                // Under 25 GB will not hold a typical library.
                .foregroundStyle(free < 25_000_000_000 ? .orange : .secondary)
                .help("Space left on this volume. A full photo library commonly runs to several hundred gigabytes.")
                .fixedSize()
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
        let count = n.formatted()
        return onlyNew && dest.plan != nil ? "Download \(count) New" : "Download \(count)"
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
