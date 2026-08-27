import AppKit
import Photos
import SwiftUI

/// Why an album in the sidebar has nothing in it, when the reason is macOS rather
/// than the album genuinely being empty.
enum AlbumNotice {
    case hiddenLocked
    case recentlyDeleted
}

/// One selectable album in the sidebar.
struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let symbol: String
    let collection: PHAssetCollection?   // nil == the whole library
    var includesHidden = false           // Hidden needs an explicit fetch option
    var isShared = false                 // iCloud Shared Album -- see note below
    var notice: AlbumNotice?             // non-nil == cannot be read, explain why

    static func == (a: Album, b: Album) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let albums: [Album]
}

/// A run of assets sharing a date bucket, with its header text.
struct AssetSection: Identifiable {
    let id: String
    let title: String
    let assets: [PHAsset]
}

@MainActor
final class PhotoStore: NSObject, ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var albums: [Album] = []
    @Published var albumGroups: [AlbumGroup] = []
    @Published var assets: [PHAsset] = []
    @Published var selectedAlbum: Album?
    @Published var selection: Set<String> = []      // PHAsset.localIdentifier
    @Published var isLoading = false
    @Published private(set) var sections: [AssetSection] = []
    /// Every frame, including burst siblings the grid does not show.
    @Published private(set) var downloadableAssets: [PHAsset] = []

    @Published var grouping: DateGrouping = .day { didSet { rebuildSections() } }
    @Published var newestFirst = true { didSet { rebuildSections() } }

    private let imageManager = PHCachingImageManager()
    /// Kept so PHChange can hand back an updated fetch result for the open album.
    private var currentFetch: PHFetchResult<PHAsset>?
    private var albumReloadTask: Task<Void, Never>?
    private var observing = false

    /// Bumped whenever the library changes underneath us, so the destination
    /// analysis knows its "what is still missing" answer is stale.
    @Published private(set) var libraryVersion = 0
    /// Photos that appeared since this window opened.
    @Published private(set) var arrivedSinceOpen = 0

    override init() {
        super.init()
        if isAuthorized { startObserving() }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func startObserving() {
        guard !observing else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    var isAuthorized: Bool { status == .authorized || status == .limited }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard isAuthorized else { return }
        startObserving()
        loadAlbums()
    }

    // MARK: - Albums

    /// Fetch options for an album. Hidden assets and shared-album assets are both
    /// excluded from ordinary fetches, so each needs opting into explicitly.
    private func fetchOptions(for album: Album, sorted: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        if sorted {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        if album.includesHidden { options.includeHiddenAssets = true }
        return options
    }

    func loadAlbums() {
        var groups: [AlbumGroup] = []

        // --- Library ---
        var library: [Album] = [
            Album(id: "__all__", title: "All Photos",
                  count: PHAsset.fetchAssets(with: nil).count,
                  symbol: "photo.on.rectangle.angled", collection: nil)
        ]
        let hiddenOptions = PHFetchOptions()
        hiddenOptions.includeHiddenAssets = true
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                subtype: .smartAlbumAllHidden,
                                                options: nil)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: hiddenOptions).count
                library.append(Album(id: collection.localIdentifier,
                                     title: collection.localizedTitle ?? "Hidden",
                                     count: count,
                                     symbol: "eye.slash",
                                     collection: collection,
                                     includesHidden: true,
                                     notice: count == 0 ? .hiddenLocked : nil))
            }

        // Listed deliberately even though PhotoKit cannot read it. Omitting it silently
        // makes an Apple restriction look like a missing feature, and this is the first
        // place someone goes looking.
        library.append(Album(id: "__recently_deleted__", title: "Recently Deleted",
                             count: 0, symbol: "trash.slash", collection: nil,
                             notice: .recentlyDeleted))
        groups.append(AlbumGroup(id: "library", title: "Library", albums: library))

        // --- Smart albums ---
        // Fetched with .any rather than a fixed list, so undocumented-but-real
        // collections (Recently Saved, Captured by Me, Dual Capture...) show up too.
        // The curated order below covers the ones people actually look for; anything
        // else follows alphabetically.
        let symbols: [Int: String] = [
            203: "heart", 206: "clock", 202: "video", 213: "livephoto",
            210: "person.crop.square", 211: "camera.viewfinder", 220: "record.circle",
            201: "pano", 207: "square.stack.3d.down.right", 208: "slowmo",
            204: "timelapse", 217: "camera.aperture", 218: "film", 212: "f.cursive",
            215: "plusminus.circle", 214: "square.stack.3d.forward.dottedline",
            219: "cube.transparent", 216: "exclamationmark.icloud", 221: "camera.on.rectangle",
        ]
        let order = [203, 206, 202, 213, 210, 211, 220, 201, 207,
                     208, 204, 217, 218, 212, 215, 214, 219, 221, 216]

        var ranked: [(rank: Int, album: Album)] = []
        var seen = Set<String>()

        func consider(_ collection: PHAssetCollection) {
            let subtype = collection.assetCollectionSubtype.rawValue
            // 209 is Recents, identical to All Photos; 205 is Hidden, listed above.
            guard subtype != 209, subtype != 205 else { return }
            guard seen.insert(collection.localIdentifier).inserted else { return }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            ranked.append((order.firstIndex(of: subtype) ?? Int.max,
                           Album(id: collection.localIdentifier,
                                 title: collection.localizedTitle ?? "Untitled",
                                 count: count,
                                 symbol: symbols[subtype] ?? "sparkles",
                                 collection: collection)))
        }

        // Ask for the known subtypes by name first: PhotoKit leaves some of them out
        // of a .any enumeration (Recently Added is one) but returns them on request.
        for subtype in order {
            guard let value = PHAssetCollectionSubtype(rawValue: subtype) else { continue }
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: value,
                                                    options: nil)
                .enumerateObjects { collection, _, _ in consider(collection) }
        }
        // Then sweep up everything else, including undocumented subtypes.
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in consider(collection) }

        let smart = ranked
            .sorted { a, b in
                a.rank != b.rank ? a.rank < b.rank
                    : a.album.title.localizedStandardCompare(b.album.title) == .orderedAscending
            }
            .map(\.album)

        if !smart.isEmpty {
            groups.append(AlbumGroup(id: "smart", title: "Smart Albums", albums: smart))
        }

        // --- User albums, split into own vs shared and sorted by name ---
        var mine: [Album] = []
        var shared: [Album] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                guard count > 0 else { return }
                let isShared = collection.assetCollectionSubtype == .albumCloudShared
                let realTitle = collection.localizedTitle ?? "Untitled"
                let shownTitle = Demo.enabled
                    ? Demo.albumName(realTitle,
                                     index: isShared ? shared.count : mine.count,
                                     shared: isShared)
                    : realTitle
                let album = Album(id: collection.localIdentifier,
                                  title: shownTitle,
                                  count: count,
                                  symbol: isShared ? "person.2" : "rectangle.stack",
                                  collection: collection,
                                  isShared: isShared)
                if isShared { shared.append(album) } else { mine.append(album) }
            }

        let byName: (Album, Album) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        if !mine.isEmpty {
            groups.append(AlbumGroup(id: "mine", title: "My Albums",
                                     albums: mine.sorted(by: byName)))
        }
        if !shared.isEmpty {
            groups.append(AlbumGroup(id: "shared", title: "Shared Albums",
                                     albums: shared.sorted(by: byName)))
        }

        albumGroups = groups
        albums = groups.flatMap(\.albums)
        if selectedAlbum == nil { select(albums.first) }
    }

    // MARK: - Assets

    func select(_ album: Album?) {
        selectedAlbum = album
        selection.removeAll()
        guard let album else { assets = []; downloadableAssets = []; rebuildSections(); return }

        // Placeholder rows have no collection to fetch -- a nil collection otherwise
        // means "the whole library", which would be badly wrong here.
        if album.notice == .recentlyDeleted {
            assets = []
            downloadableAssets = []
            rebuildSections()
            return
        }

        isLoading = true
        let options = fetchOptions(for: album, sorted: true)

        let result = album.collection.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)
        currentFetch = result

        var loaded: [PHAsset] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }

        assets = loaded
        downloadableAssets = expandingBursts(loaded)
        imageManager.stopCachingImagesForAllAssets()
        rebuildSections()
        isLoading = false
    }

    /// Assets are fetched newest-first; reversing is cheaper than a second fetch.
    private var orderedAssets: [PHAsset] { newestFirst ? assets : assets.reversed() }

    private func rebuildSections() {
        let ordered = orderedAssets
        sections = groupConsecutive(dates: ordered.map(\.creationDate), grouping: grouping)
            .map { group in
                let slice = Array(ordered[group.range])
                return AssetSection(id: group.key,
                                    title: groupLabel(slice.first?.creationDate, grouping),
                                    assets: slice)
            }
    }

    /// Select the whole section, or clear it if every item is already selected.
    func toggleSection(_ section: AssetSection) {
        let ids = section.assets.map(\.localIdentifier)
        if ids.allSatisfy(selection.contains) {
            ids.forEach { selection.remove($0) }
        } else {
            selection.formUnion(ids)
        }
    }

    // MARK: - Selection

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAll() { selection = Set(assets.map(\.localIdentifier)) }
    func selectNone() { selection.removeAll() }

    /// Assets to download: the explicit selection, or the whole album when nothing is
    /// picked. Either way burst siblings ride along with their representative.
    var effectiveAssets: [PHAsset] {
        guard !selection.isEmpty else { return downloadableAssets }
        return expandingBursts(assets.filter { selection.contains($0.localIdentifier) })
    }

    // MARK: - Thumbnails

    func thumbnail(for asset: PHAsset, size: CGFloat) async -> NSImage? {
        if Demo.enabled {
            return Demo.thumbnail(seed: asset.localIdentifier, size: size)
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // pull from iCloud if not cached locally
        let target = CGSize(width: size * 2, height: size * 2)   // 2x for Retina

        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: target,
                                      contentMode: .aspectFill, options: options) { image, info in
                // .opportunistic fires twice (degraded, then full). Resume once, on the last.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}


// MARK: - Live library updates

extension PhotoStore: PHPhotoLibraryChangeObserver {
    /// Called on an arbitrary serial queue, so everything real happens on the main actor.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.apply(changeInstance) }
    }

    private func apply(_ change: PHChange) {
        guard let fetch = currentFetch,
              let details = change.changeDetails(for: fetch) else { return }

        currentFetch = details.fetchResultAfterChanges
        var loaded: [PHAsset] = []
        loaded.reserveCapacity(details.fetchResultAfterChanges.count)
        details.fetchResultAfterChanges.enumerateObjects { asset, _, _ in loaded.append(asset) }

        assets = loaded
        downloadableAssets = expandingBursts(loaded)

        // Selection is held by identifier, so it survives a reload -- drop only the
        // entries whose photo genuinely went away. Wiping it here would be maddening
        // for someone half way through picking a few hundred photos.
        let live = Set(loaded.map(\.localIdentifier))
        selection.formIntersection(live)

        rebuildSections()
        arrivedSinceOpen += details.insertedObjects.count
        libraryVersion += 1

        // Counts across every album may have moved too. Debounced, because an import
        // fires a burst of changes and recounting 60 albums each time is wasteful.
        albumReloadTask?.cancel()
        albumReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.loadAlbums()
        }
    }
}
