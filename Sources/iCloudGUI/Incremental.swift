import Foundation
import Photos

/// Every relative path one asset should produce, given the current options.
/// Shared by the analyzer and the downloader so they can never disagree.
func plannedPaths(for asset: PHAsset,
                  includeUnmodifiedOriginals: Bool,
                  layout: FolderLayout,
                  datePrefix: Bool) -> [String] {
    let resources = PHAssetResource.assetResources(for: asset)
    return planResources(types: resources.map(\.type),
                         includeUnmodifiedOriginals: includeUnmodifiedOriginals)
        .map { planned in
            relativePath(creationDate: asset.creationDate,
                         filename: resources[planned.index].originalFilename,
                         role: planned.role,
                         layout: layout,
                         datePrefix: datePrefix)
        }
}

/// Space left on the volume holding `url`, or nil if it cannot be determined.
///
/// Worth showing: a full library runs to hundreds of gigabytes, and the default
/// destination is inside the home folder, where running out mid-run is a real outcome.
func availableBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}

/// Maps every asset to the albums it belongs to, for Finder tagging.
///
/// Built by walking each album once rather than asking per asset: 60-odd album fetches
/// instead of tens of thousands of per-asset queries.
func buildAlbumMembershipIndex() -> [String: [String]] {
    var index: [String: [String]] = [:]
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        .enumerateObjects { collection, _, _ in
            guard let name = collection.localizedTitle, !name.isEmpty else { return }
            PHAsset.fetchAssets(in: collection, options: nil)
                .enumerateObjects { asset, _, _ in
                    index[asset.localIdentifier, default: []].append(name)
                }
        }
    return index
}

/// Finder tags for one asset: its favourite status plus every album it appears in.
func finderTags(for asset: PHAsset, albumIndex: [String: [String]]) -> [String] {
    var tags = albumIndex[asset.localIdentifier] ?? []
    if asset.isFavorite { tags.append("Favorite") }
    return tags
}

/// Burst sets surface as a single representative asset; the remaining frames are real
/// assets that PhotoKit withholds unless asked for. Photos.app hides them the same way,
/// so the grid keeps one tile per burst while a download covers every frame -- silently
/// dropping them would leave gaps in what is meant to be a complete backup.
func expandingBursts(_ assets: [PHAsset]) -> [PHAsset] {
    var out: [PHAsset] = []
    var seen = Set<String>()
    out.reserveCapacity(assets.count)

    for asset in assets {
        if seen.insert(asset.localIdentifier).inserted { out.append(asset) }
        guard asset.representsBurst, let burstID = asset.burstIdentifier else { continue }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        PHAsset.fetchAssets(withBurstIdentifier: burstID, options: options)
            .enumerateObjects { sibling, _, _ in
                if seen.insert(sibling.localIdentifier).inserted { out.append(sibling) }
            }
    }
    return out
}

/// Append-only record of which asset produced which file, kept at the destination root.
///
/// The filesystem remains the source of truth. This only supplies identity, which
/// filenames cannot: two photos from different devices are both `IMG_0001.HEIC`, and
/// on the same day they collide in the same folder. Without this, the second one is
/// silently skipped as "already downloaded".
///
/// Deleting this file degrades to filename matching rather than breaking, and the
/// photos are plain files in date folders regardless -- nothing requires this app.
struct DownloadLedger {
    static let filename = ".icloudgui-index.tsv"

    let url: URL
    private(set) var pathsByAsset: [String: [String]] = [:]
    private var pending: [String] = []

    init(destination: URL) {
        url = destination.appendingPathComponent(Self.filename)
        load()
    }

    private mutating func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            pathsByAsset[String(parts[0]), default: []].append(String(parts[1]))
        }
    }

    func paths(for assetID: String) -> [String] { pathsByAsset[assetID] ?? [] }

    /// Drops rows whose file is no longer on disk and rewrites the log.
    ///
    /// This is what makes the ledger self-healing: delete a photo from the NAS and its
    /// row disappears, so the asset falls back to filename matching and gets fetched
    /// again. Without it, a stale row would claim forever that the file is present.
    mutating func prune(keeping existing: Set<String>) {
        var kept: [String: [String]] = [:]
        var changed = false
        for (assetID, paths) in pathsByAsset {
            let surviving = paths.filter(existing.contains)
            if surviving.count != paths.count { changed = true }
            if !surviving.isEmpty { kept[assetID] = surviving }
        }
        guard changed else { return }
        pathsByAsset = kept
        let rows = kept.flatMap { id, paths in paths.map { "\(id)\t\($0)" } }
        try? (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Buffered so a NAS does not take a network round trip per photo.
    mutating func record(assetID: String, relativePath: String) {
        pathsByAsset[assetID, default: []].append(relativePath)
        pending.append("\(assetID)\t\(relativePath)")
        if pending.count >= 50 { flush() }
    }

    mutating func flush() {
        guard !pending.isEmpty else { return }
        let blob = pending.joined(separator: "\n") + "\n"
        pending.removeAll(keepingCapacity: true)
        guard let data = blob.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)   // first write creates the file
        }
    }
}

/// Append-only record of what each run did, kept beside the ledger.
///
/// The ledger records successes. Without this, failures live only in `@Published`
/// state and vanish when the app quits — so a run that silently drops forty photos
/// overnight leaves no evidence of which forty. For a backup tool, what did *not* make
/// it matters as much as what did.
///
/// Written unbuffered: a crash mid-run must not take the record of the failures with it.
struct RunLog {
    static let filename = ".icloudgui-log.txt"
    private let url: URL

    init(destination: URL) {
        url = destination.appendingPathComponent(Self.filename)
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func started(items: Int, options: String) {
        append("RUN START\t\(items) items\t\(options)")
    }

    func failed(filename: String, assetID: String, reason: String) {
        append("FAILED\t\(filename)\t\(assetID)\t\(reason)")
    }

    func finished(_ summary: String) {
        append("RUN END\t\(summary)")
    }

    func note(_ detail: String) {
        append("NOTE\t\(detail)")
    }

    private func append(_ line: String) {
        let row = "\(Self.stamp.string(from: Date()))\t\(line)\n"
        guard let data = row.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

// MARK: - Destination scan

enum DestinationScanner {
    /// One bulk enumeration of the destination tree, returning relative paths.
    ///
    /// Deliberately not a `fileExists` per expected file: over SMB that is one network
    /// round trip each, so 40k photos becomes 40k round trips. This is a few directory reads.
    static func scan(root: URL, onProgress: (Int) -> Void) -> Set<String> {
        var found: Set<String> = []
        let prefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"

        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return found }

        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if url.pathExtension == "part" { continue }   // interrupted, not real
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            found.insert(String(path.dropFirst(prefix.count)))
            if found.count % 500 == 0 { onProgress(found.count) }
        }
        onProgress(found.count)
        return found
    }
}

// MARK: - Analysis

struct IncrementalPlan {
    var newAssets: [PHAsset] = []
    var completeCount = 0
    var newFileCount = 0

    var isEmpty: Bool { newAssets.isEmpty }
}

/// Paths this asset still needs; empty means the destination already has it.
///
/// `recorded` must already be pruned to files that exist, so a non-empty value means
/// the ledger positively identifies this asset's files -- exactly the question a
/// filename cannot answer. Only when the ledger knows nothing do we fall back to
/// matching planned filenames, which cannot distinguish two same-named photos in one
/// day folder. `planned` is an autoclosure so that fallback stays unevaluated on the
/// fast path, where it would cost a PhotoKit query per asset.
func missingPaths(recorded: [String],
                  planned: @autoclosure () -> [String],
                  existing: Set<String>) -> [String] {
    guard recorded.isEmpty else { return [] }
    return planned().filter { !existing.contains($0) }
}

/// Decides, per asset, whether the destination already holds every file it should produce.
///
/// Ledger entries are exact. Assets with no ledger entry (downloaded by an older build,
/// or by another tool into this layout) fall back to matching planned filenames, which
/// cannot distinguish two same-named photos in one day folder -- the ledger exists to
/// stop that recurring going forward.
func analyzeIncremental(
    assets: [PHAsset],
    existing: Set<String>,
    ledger: DownloadLedger,
    includeUnmodifiedOriginals: Bool,
    layout: FolderLayout,
    datePrefix: Bool,
    onProgress: (Int) -> Void
) -> IncrementalPlan {
    var plan = IncrementalPlan()

    for (offset, asset) in assets.enumerated() {
        if offset % 250 == 0 { onProgress(offset) }

        let missing = missingPaths(
            recorded: ledger.paths(for: asset.localIdentifier),
            planned: plannedPaths(for: asset,
                                  includeUnmodifiedOriginals: includeUnmodifiedOriginals,
                                  layout: layout,
                                  datePrefix: datePrefix),
            existing: existing)

        if missing.isEmpty {
            plan.completeCount += 1
        } else {
            plan.newAssets.append(asset)
            plan.newFileCount += missing.count
        }
    }
    onProgress(assets.count)
    return plan
}

// MARK: - View model

/// Tracks what the chosen destination already contains.
@MainActor
final class DestinationModel: ObservableObject {
    @Published var url: URL?
    @Published private(set) var isWorking = false
    @Published private(set) var statusText = ""
    @Published private(set) var plan: IncrementalPlan?
    @Published private(set) var newAssetIDs: Set<String> = []
    @Published private(set) var existing: Set<String> = []

    private var job: Task<Void, Never>?

    func invalidate() {
        job?.cancel()
        plan = nil
        newAssetIDs = []
        existing = []
        statusText = ""
        isWorking = false
    }

    /// Scans the destination, then works out which of `assets` are still missing.
    func refresh(assets: [PHAsset], includeUnmodifiedOriginals: Bool,
                 layout: FolderLayout, datePrefix: Bool) {
        job?.cancel()
        guard let root = url, !assets.isEmpty else { invalidate(); return }

        isWorking = true
        plan = nil
        statusText = "Scanning destination…"

        job = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                DestinationScanner.scan(root: root) { _ in }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.existing = found
            self.statusText = "Comparing \(assets.count.formatted()) items…"

            var ledger = DownloadLedger(destination: root)
            ledger.prune(keeping: found)
            let result = await Task.detached(priority: .userInitiated) {
                analyzeIncremental(assets: assets,
                                   existing: found,
                                   ledger: ledger,
                                   includeUnmodifiedOriginals: includeUnmodifiedOriginals,
                                   layout: layout,
                                   datePrefix: datePrefix) { _ in }
            }.value
            guard !Task.isCancelled else { return }

            self.plan = result
            self.newAssetIDs = Set(result.newAssets.map(\.localIdentifier))
            self.statusText = Self.describe(result)
            self.isWorking = false
        }
    }

    private static func describe(_ plan: IncrementalPlan) -> String {
        if plan.isEmpty { return "Everything here is already downloaded." }
        var text = "\(plan.newAssets.count.formatted()) new"
        if plan.newFileCount != plan.newAssets.count {
            text += " (\(plan.newFileCount.formatted()) files)"
        }
        if plan.completeCount > 0 {
            text += " · \(plan.completeCount.formatted()) already downloaded"
        }
        return text
    }
}
