import Foundation
import Photos

struct DownloadProgress {
    var completed = 0
    var total = 0
    var skipped = 0
    var failed = 0
    var currentFile = ""
    var bytesWritten: Int64 = 0
    var isRunning = false
    var finishedMessage: String?
    /// 0...1 for the file currently streaming, nil when nothing is mid-flight.
    var currentFileFraction: Double?
}

struct DownloadFailure: Identifiable {
    let id = UUID()
    let filename: String
    let assetID: String
    let reason: String
}

@MainActor
final class Downloader: ObservableObject {
    @Published private(set) var progress = DownloadProgress()
    @Published private(set) var failures: [DownloadFailure] = []

    private var task: Task<Void, Never>?
    private var ledger: DownloadLedger?
    private var log: RunLog?
    private var tagsRequested = 0
    private var tagsWritten = 0

    /// iCloud throttles aggressive parallel pulls, and each in-flight resource
    /// buffers on disk. Four is comfortably faster than serial without tripping it.
    private let maxConcurrent = 4

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(assets: [PHAsset],
               destination: URL,
               existing: Set<String>,
               includeUnmodifiedOriginals: Bool,
               layout: FolderLayout,
               datePrefix: Bool,
               writeFinderTags: Bool) {
        cancel()
        failures = []
        progress = DownloadProgress(total: assets.count, isRunning: true)
        ledger = DownloadLedger(destination: destination)
        log = RunLog(destination: destination)
        tagsRequested = 0
        tagsWritten = 0
        log?.started(items: assets.count,
                     options: [layout.rawValue,
                               datePrefix ? "dated-names" : "plain-names",
                               includeUnmodifiedOriginals ? "with-originals" : "edited-only",
                               writeFinderTags ? "tags" : "no-tags"].joined(separator: " "))

        task = Task { [weak self] in
            await self?.run(assets: assets,
                            destination: destination,
                            existing: existing,
                            includeUnmodifiedOriginals: includeUnmodifiedOriginals,
                            layout: layout,
                            datePrefix: datePrefix,
                            writeFinderTags: writeFinderTags)
        }
    }

    private func run(assets: [PHAsset],
                     destination: URL,
                     existing: Set<String>,
                     includeUnmodifiedOriginals: Bool,
                     layout: FolderLayout,
                     datePrefix: Bool,
                     writeFinderTags: Bool) async {
        // A 200 GB library takes hours. Idle sleep would stall every transfer, so hold
        // the system awake for the run. Note this does not survive closing the lid --
        // that sleeps regardless.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled,
                      .automaticTerminationDisabled],
            reason: "Downloading photos from iCloud")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // One pass over the albums up front beats a per-asset membership query.
        var albumIndex: [String: [String]] = [:]
        if writeFinderTags {
            progress.currentFile = "Indexing albums…"
            albumIndex = await Task.detached(priority: .userInitiated) {
                buildAlbumMembershipIndex()
            }.value
            progress.currentFile = ""
        }

        // Bounded concurrency: keep `maxConcurrent` asset downloads in flight.
        await withTaskGroup(of: AssetOutcome.self) { group in
            var next = 0
            var inFlight = 0
            // Bound once here rather than capturing self inside each child task,
            // which Swift 6 rejects as a concurrent capture of a mutable binding.
            let reportProgress: @Sendable (String, Double) -> Void = { [weak self] name, fraction in
                Task { @MainActor in self?.report(file: name, fraction: fraction) }
            }

            func addTask() {
                guard next < assets.count else { return }
                let asset = assets[next]
                next += 1
                inFlight += 1
                let tags = writeFinderTags ? finderTags(for: asset, albumIndex: albumIndex) : []
                group.addTask {
                    await Self.download(asset: asset,
                                        destination: destination,
                                        existing: existing,
                                        includeUnmodifiedOriginals: includeUnmodifiedOriginals,
                                        layout: layout,
                                        datePrefix: datePrefix,
                                        tags: tags,
                                        onFileProgress: reportProgress)
                }
            }

            for _ in 0..<maxConcurrent { addTask() }

            while inFlight > 0, let outcome = await group.next() {
                inFlight -= 1
                apply(outcome)
                if Task.isCancelled { break }
                addTask()
            }
            group.cancelAll()
        }

        ledger?.flush()
        progress.isRunning = false
        progress.currentFileFraction = nil
        progress.finishedMessage = Task.isCancelled
            ? "Cancelled after \(progress.completed) item\(progress.completed == 1 ? "" : "s")."
            : summary()
        // Tagging failing quietly is how a broken feature shipped; say so either way.
        if writeFinderTags {
            log?.note("Finder tags written on \(tagsWritten) of \(tagsRequested) files")
        }
        log?.finished(progress.finishedMessage ?? "")
    }

    /// Live progress for the file currently streaming.
    ///
    /// ponytail: with four downloads in flight this shows whichever reported last,
    /// so the bar can jump between files. Ceiling: it is an activity indicator, not a
    /// precise per-item measure. Upgrade path: key progress by filename and surface a
    /// row per in-flight download.
    private func report(file: String, fraction: Double) {
        guard progress.isRunning else { return }
        progress.currentFile = file
        progress.currentFileFraction = fraction < 1 ? fraction : nil
    }

    private func apply(_ outcome: AssetOutcome) {
        progress.completed += 1
        tagsRequested += outcome.tagsRequested
        tagsWritten += outcome.tagsWritten
        progress.skipped += outcome.skipped
        progress.bytesWritten += outcome.bytes
        if let name = outcome.lastFilename { progress.currentFile = name }
        // Recorded here, on the main actor, so concurrent downloads serialize naturally.
        for entry in outcome.written {
            ledger?.record(assetID: entry.assetID, relativePath: entry.relativePath)
        }
        for failure in outcome.failures {
            progress.failed += 1
            failures.append(failure)
            log?.failed(filename: failure.filename,
                        assetID: failure.assetID,
                        reason: failure.reason)
        }
    }

    private func summary() -> String {
        let written = progress.completed - progress.failed
        var parts = ["Downloaded \(written) item\(written == 1 ? "" : "s")"]
        if progress.bytesWritten > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: progress.bytesWritten,
                                                   countStyle: .file))
        }
        if progress.skipped > 0 { parts.append("\(progress.skipped) already present") }
        if progress.failed > 0 { parts.append("\(progress.failed) failed") }
        return parts.joined(separator: " · ") + "."
    }

    // MARK: - Per-asset work (off the main actor)

    private struct WrittenFile {
        let assetID: String
        let relativePath: String
    }

    private struct AssetOutcome {
        var bytes: Int64 = 0
        var skipped = 0
        var failures: [DownloadFailure] = []
        var written: [WrittenFile] = []
        var lastFilename: String?
        var tagsRequested = 0
        var tagsWritten = 0
    }

    private nonisolated static func download(
        asset: PHAsset,
        destination: URL,
        existing: Set<String>,
        includeUnmodifiedOriginals: Bool,
        layout: FolderLayout,
        datePrefix: Bool,
        tags: [String],
        onFileProgress: @escaping @Sendable (String, Double) -> Void
    ) async -> AssetOutcome {
        var outcome = AssetOutcome()
        let resources = PHAssetResource.assetResources(for: asset)
        let plan = planResources(types: resources.map(\.type),
                                 includeUnmodifiedOriginals: includeUnmodifiedOriginals)

        for planned in plan {
            if Task.isCancelled { return outcome }
            let resource = resources[planned.index]
            let relative = relativePath(creationDate: asset.creationDate,
                                        filename: resource.originalFilename,
                                        role: planned.role,
                                        layout: layout,
                                        datePrefix: datePrefix)
            outcome.lastFilename = (relative as NSString).lastPathComponent

            // Membership in the pre-built index, not a fileExists() call: on a NAS the
            // latter is a network round trip per file.
            if existing.contains(relative) {
                outcome.skipped += 1
                continue
            }

            do {
                let name = (relative as NSString).lastPathComponent
                let written = try await write(resource: resource,
                                              to: destination.appendingPathComponent(relative),
                                              root: destination,
                                              creationDate: asset.creationDate,
                                              tags: tags,
                                              onProgress: { onFileProgress(name, $0) })
                outcome.bytes += written.bytes
                if written.tagCount > 0 {
                    outcome.tagsRequested += 1
                    if written.tagged { outcome.tagsWritten += 1 }
                }
                // Record the path actually used -- uniqueURL may have disambiguated it.
                outcome.written.append(WrittenFile(assetID: asset.localIdentifier,
                                                   relativePath: written.relativePath))
            } catch {
                outcome.failures.append(
                    DownloadFailure(filename: (relative as NSString).lastPathComponent,
                                    assetID: asset.localIdentifier,
                                    reason: error.localizedDescription))
            }
        }
        return outcome
    }

    private struct WriteResult {
        let bytes: Int64
        let relativePath: String
        let tagged: Bool
        let tagCount: Int
    }

    /// Streams one resource to disk. Writes to a sibling `.part` file and renames
    /// on success so an interrupted run never leaves a truncated photo behind.
    private nonisolated static func write(resource: PHAssetResource,
                                          to target: URL,
                                          root: URL,
                                          creationDate: Date?,
                                          tags: [String],
                                          onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WriteResult {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // Breaks same-name collisions between *different* assets, which recur across
        // devices and years. The chosen name is what gets recorded in the ledger.
        let finalURL = uniqueURL(target) { fm.fileExists(atPath: $0.path) }
        let partURL = finalURL.appendingPathExtension("part")
        try? fm.removeItem(at: partURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // this is what pulls it down from iCloud
        options.progressHandler = onProgress    // fires on an arbitrary queue

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: partURL,
                                                       options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        try fm.moveItem(at: partURL, to: finalURL)
        applyTimestamps(to: finalURL, creationDate: creationDate)
        let tagged = applyFinderTags(to: finalURL, tags: tags)
        let attributes = try? fm.attributesOfItem(atPath: finalURL.path)
        let prefix = root.standardizedFileURL.path + "/"
        let full = finalURL.standardizedFileURL.path
        let relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count))
                                              : finalURL.lastPathComponent
        return WriteResult(bytes: (attributes?[.size] as? Int64) ?? 0,
                           relativePath: relative,
                           tagged: tagged, tagCount: tags.count)
    }
}
