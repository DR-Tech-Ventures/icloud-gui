import Foundation
import Photos

/// Diagnostic: reports what TCC actually says, to a file (stdout is lost under `open`).
enum Probe {
    /// Read-only: reports status without triggering a prompt.
    static func status() -> Never {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try? name(s).write(to: URL(fileURLWithPath: "/tmp/icloudgui-status.txt"),
                           atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Diagnostic: dump what collections this library actually contains.
    static func albums() -> Never {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); print(s) }

        let hiddenOpts = PHFetchOptions(); hiddenOpts.includeHiddenAssets = true
        let hidden = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
        note("--- hidden ---")
        hidden.enumerateObjects { c, _, _ in
            let withOpt = PHAsset.fetchAssets(in: c, options: hiddenOpts).count
            let without = PHAsset.fetchAssets(in: c, options: nil).count
            note("  \(c.localizedTitle ?? "?"): includeHidden=\(withOpt) default=\(without)")
        }

        note("--- cloud shared albums ---")
        let shared = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil)
        note("  count: \(shared.count)")
        let srcOpts = PHFetchOptions()
        srcOpts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        shared.enumerateObjects { c, _, _ in
            let withOpt = PHAsset.fetchAssets(in: c, options: srcOpts).count
            let without = PHAsset.fetchAssets(in: c, options: nil).count
            note("  \(c.localizedTitle ?? "?"): withSourceTypes=\(withOpt) default=\(without)")
        }

        note("--- my albums (not shared) ---")
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { c, _, _ in
                guard c.assetCollectionSubtype != .albumCloudShared else { return }
                let n = PHAsset.fetchAssets(in: c, options: nil).count
                note("  \(c.localizedTitle ?? "?"): \(n)")
            }

        note("--- regular albums (subtype breakdown) ---")
        var bySubtype: [Int: Int] = [:]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { c, _, _ in bySubtype[c.assetCollectionSubtype.rawValue, default: 0] += 1 }
        for (k, v) in bySubtype.sorted(by: { $0.key < $1.key }) { note("  subtype \(k): \(v) albums") }

        // Shared albums are widely said to store downscaled copies -- check, don't assume.
        note("--- shared vs own resolution ---")
        if let first = shared.firstObject {
            let a = PHAsset.fetchAssets(in: first, options: nil)
            var dims: [String] = []
            a.enumerateObjects { asset, i, stop in
                if i >= 5 { stop.pointee = true; return }
                let res = PHAssetResource.assetResources(for: asset)
                dims.append("\(asset.pixelWidth)x\(asset.pixelHeight) [\(res.map { String(describing: $0.type.rawValue) }.joined(separator: ","))]")
            }
            note("  shared '\(first.localizedTitle ?? "?")': \(dims.joined(separator: " "))")
        }
        var ownDims: [String] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { asset, i, stop in
            if i >= 5 { stop.pointee = true; return }
            ownDims.append("\(asset.pixelWidth)x\(asset.pixelHeight)")
        }
        note("  own library: \(ownDims.joined(separator: " "))")

        note("--- all photos, source types ---")
        note("  default: \(PHAsset.fetchAssets(with: nil).count)")
        note("  withSourceTypes: \(PHAsset.fetchAssets(with: srcOpts).count)")
        let hidOpts = PHFetchOptions(); hidOpts.includeHiddenAssets = true
        note("  includeHidden: \(PHAsset.fetchAssets(with: hidOpts).count)")

        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/icg-albums.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Diagnostic: why does the Hidden album come back empty?
    static func hidden() -> Never {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); print(s) }

        note("--- every smart album PhotoKit will admit to ---")
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { c, _, _ in
                let opts = PHFetchOptions(); opts.includeHiddenAssets = true
                let n = PHAsset.fetchAssets(in: c, options: opts).count
                note("  [\(c.assetCollectionSubtype.rawValue)] \(c.localizedTitle ?? "?") = \(n)")
            }

        note("--- hidden assets by property scan ---")
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        let all = PHAsset.fetchAssets(with: opts)
        var hiddenCount = 0
        all.enumerateObjects { a, _, _ in if a.isHidden { hiddenCount += 1 } }
        note("  fetched \(all.count) assets, isHidden==true on \(hiddenCount)")

        let plain = PHAsset.fetchAssets(with: nil)
        var hiddenPlain = 0
        plain.enumerateObjects { a, _, _ in if a.isHidden { hiddenPlain += 1 } }
        note("  without includeHiddenAssets: \(plain.count) assets, isHidden==true on \(hiddenPlain)")

        note("--- AllHidden collection, option combos ---")
        let hid = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
        note("  collections found: \(hid.count)")
        hid.enumerateObjects { c, _, _ in
            let a = PHFetchOptions(); a.includeHiddenAssets = true
            let b = PHFetchOptions(); b.includeHiddenAssets = true
            b.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
            note("  title=\(c.localizedTitle ?? "?") estimated=\(c.estimatedAssetCount)")
            note("    default=\(PHAsset.fetchAssets(in: c, options: nil).count)")
            note("    includeHidden=\(PHAsset.fetchAssets(in: c, options: a).count)")
            note("    +sourceTypes=\(PHAsset.fetchAssets(in: c, options: b).count)")
        }

        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/icg-hidden.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Diagnostic: what else is PhotoKit holding that we are not asking for?
    static func extras() -> Never {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); print(s) }

        note("--- burst frames ---")
        let plain = PHFetchOptions()
        let bursts = PHFetchOptions(); bursts.includeAllBurstAssets = true
        note("  default:            \(PHAsset.fetchAssets(with: plain).count)")
        note("  includeAllBursts:   \(PHAsset.fetchAssets(with: bursts).count)")

        var all: [PHAsset] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in all.append(a) }
        let expanded = expandingBursts(all)
        note("  expandingBursts():  \(expanded.count)  (from \(all.count))")
        note("  unique ids:         \(Set(expanded.map(\.localIdentifier)).count)")

        note("--- iTunes-synced assets ---")
        let src = PHFetchOptions()
        src.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        note("  userLibrary+shared: \(PHAsset.fetchAssets(with: src).count)")

        note("--- filenames and metadata (sample of 400) ---")
        var uuidNames = 0, favorites = 0, noDate = 0, withLocation = 0, sampled = 0
        var examples: [String] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { asset, i, stop in
            if i >= 400 { stop.pointee = true; return }
            sampled += 1
            if asset.isFavorite { favorites += 1 }
            if asset.creationDate == nil { noDate += 1 }
            if asset.location != nil { withLocation += 1 }
            guard let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
            else { return }
            let base = (name as NSString).deletingPathExtension
            // 8-4-4-4-12 hex == a UUID standing in for a real filename
            if base.count == 36, base.filter({ $0 == "-" }).count == 4 {
                uuidNames += 1
                if examples.count < 2 { examples.append(name) }
            }
        }
        note("  sampled:        \(sampled)")
        note("  UUID filenames: \(uuidNames)  \(examples.joined(separator: " "))")
        note("  favorites:      \(favorites)")
        note("  missing date:   \(noDate)")
        note("  with location:  \(withLocation)")

        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/icg-extras.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Diagnostic only: estimate the size of a full backup.
    /// Uses the undocumented `fileSize` key because PHAssetResource exposes no public
    /// size. Never used by the app itself -- only to answer "how much room do I need?".
    static func size() -> Never {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); print(s) }

        let all = PHAsset.fetchAssets(with: nil)
        let sampleTarget = 900
        let stride = max(1, all.count / sampleTarget)

        var sampled = 0
        var bytes: Int64 = 0
        var photoBytes: Int64 = 0, videoBytes: Int64 = 0
        var photos = 0, videos = 0

        all.enumerateObjects { asset, i, _ in
            guard i % stride == 0 else { return }
            let resources = PHAssetResource.assetResources(for: asset)
            let plan = planResources(types: resources.map(\.type),
                                     includeUnmodifiedOriginals: false)
            var assetBytes: Int64 = 0
            for planned in plan {
                if let n = resources[planned.index].value(forKey: "fileSize") as? Int64 {
                    assetBytes += n
                }
            }
            guard assetBytes > 0 else { return }
            sampled += 1
            bytes += assetBytes
            if asset.mediaType == .video { videos += 1; videoBytes += assetBytes }
            else { photos += 1; photoBytes += assetBytes }
        }

        guard sampled > 0 else { note("  could not read sizes"); exit(1) }
        let mean = Double(bytes) / Double(sampled)
        let totalGB = mean * Double(all.count) / 1_073_741_824

        func mb(_ b: Int64, _ n: Int) -> String {
            n == 0 ? "n/a" : String(format: "%.1f MB", Double(b) / Double(n) / 1_048_576)
        }
        note("  library items:    \(all.count)")
        note("  sampled:          \(sampled)")
        note("  mean per item:    \(String(format: "%.2f MB", mean / 1_048_576))")
        note("  photos avg:       \(mb(photoBytes, photos))  (\(photos) sampled)")
        note("  videos avg:       \(mb(videoBytes, videos))  (\(videos) sampled)")
        note("  ESTIMATED TOTAL:  \(String(format: "%.0f GB", totalGB))")

        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/icg-size.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Diagnostic: is the album membership index actually populated?
    static func tags() -> Never {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); print(s) }

        let index = buildAlbumMembershipIndex()
        note("index entries: \(index.count)")
        if let sample = index.first {
            note("sample: \(sample.key) -> \(sample.value.joined(separator: ", "))")
        }

        // The exact asset the end-to-end test downloaded.
        let target = "8463F8E6-DFF2-493E-88CA-E8948C106317/L0/001"
        note("target in index: \(index[target] ?? ["NOT FOUND"])")

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [target], options: nil)
        if let asset = fetched.firstObject {
            note("asset found, favourite=\(asset.isFavorite)")
            note("finderTags() -> \(finderTags(for: asset, albumIndex: index))")
        } else {
            note("asset NOT fetchable by identifier")
        }

        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/icg-tags.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    static func run() {
        let out = URL(fileURLWithPath: "/tmp/icloudgui-probe.txt")
        // A reference type rather than a local array: PhotoKit delivers the
        // authorization result on an arbitrary thread, and Swift 6 will not let a
        // closure running there capture and mutate a local var. The lock keeps the two
        // writers honest; without it this was a data race that happened not to fire.
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            let out: URL
            init(out: URL) { self.out = out }
            func note(_ s: String) {
                lock.lock()
                lines.append(s)
                let snapshot = lines.joined(separator: "\n")
                lock.unlock()
                try? snapshot.write(to: out, atomically: true, encoding: .utf8)
            }
        }
        let log = Log(out: out)
        let note = { @Sendable (s: String) in log.note(s) }

        note("bundleID: \(Bundle.main.bundleIdentifier ?? "nil")")
        note("bundlePath: \(Bundle.main.bundlePath)")
        note("usageDesc: \(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil)")
        note("before: \(name(PHPhotoLibrary.authorizationStatus(for: .readWrite)))")

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            note("after: \(name(status))")
            if status == .authorized || status == .limited {
                note("assetCount: \(PHAsset.fetchAssets(with: nil).count)")
            }
            note("DONE")
            exit(0)
        }
        // Keep the run loop alive so the callback can fire.
        RunLoop.main.run(until: Date().addingTimeInterval(45))
        note("TIMEOUT-45s")
        exit(2)
    }

    private static func name(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}
