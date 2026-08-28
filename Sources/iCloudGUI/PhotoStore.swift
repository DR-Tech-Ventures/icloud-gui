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

/// Narrows the sidebar to albums matching `query`, dropping sections that end up empty
/// so a search does not leave a column of bare headings. An empty or whitespace-only
/// query is not a filter -- it returns everything rather than nothing.
func filterAlbums(_ groups: [AlbumGroup], matching query: String) -> [AlbumGroup] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return groups }
    return groups.compactMap { group in
        let matches = group.albums.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        return matches.isEmpty ? nil
            : AlbumGroup(id: group.id, title: group.title, albums: matches)
    }
}

/// A completed fetch, carried back from the thread that ran it.
///
/// PhotoKit's types are not marked Sendable, but a PHFetchResult is a snapshot and
/// PHObject is documented immutable -- nothing here is mutated after the fetch returns,
/// and fetching off the main thread is what Apple's own guidance recommends for a
/// library this size. This box is the single place that claim is made, rather than
/// scattering @unchecked conformances across the store.
private struct AssetBatch: @unchecked Sendable {
    let fetch: PHFetchResult<PHAsset>
    let assets: [PHAsset]
    let downloadable: [PHAsset]
}

/// The collection to fetch from, on its way out to that thread. Same reasoning.
private struct CollectionRef: @unchecked Sendable {
    let collection: PHAssetCollection?
}

/// The sidebar, built on the thread that enumerated it. Same reasoning as AssetBatch:
/// PHAssetCollection is an immutable snapshot, and this pass only reads.
private struct AlbumSnapshot: @unchecked Sendable {
    let groups: [AlbumGroup]
}

/// A fetch result on its way out to the thread that will materialise it.
private struct FetchRef: @unchecked Sendable {
    let fetch: PHFetchResult<PHAsset>
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

    /// Sidebar search text. Filters the album list only -- it does not touch the grid,
    /// because PhotoKit has no text index over assets and scanning 35,000 filenames per
    /// keystroke would be worse than not offering it.
    @Published var albumFilter = ""

    /// `albumGroups` narrowed by `albumFilter`.
    var visibleGroups: [AlbumGroup] { filterAlbums(albumGroups, matching: albumFilter) }

    @Published var grouping: DateGrouping = .day { didSet { rebuildSections() } }
    @Published var newestFirst = true { didSet { rebuildSections() } }

    private let imageManager = PHCachingImageManager()
    /// Kept so PHChange can hand back an updated fetch result for the open album.
    private var currentFetch: PHFetchResult<PHAsset>?
    /// Debounces the recount that follows a library change.
    private var albumReloadTask: Task<Void, Never>?
    /// The enumeration itself. Separate from the debounce above, which used to share
    /// this handle and so cancelled the very task it was called from.
    private var albumLoadTask: Task<Void, Never>?
    private var selectTask: Task<Void, Never>?
    /// Discards a fetch that finished after a newer selection started.
    private var selectGeneration = 0
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
        // Bound to a local because os_log's interpolation is an autoclosure, and
        // referring to a property inside one needs an explicit self.
        let granted = status.rawValue
        Log.library.notice("photos authorisation: \(granted, privacy: .public)")
        guard isAuthorized else { return }
        startObserving()
        loadAlbums()
    }

    // MARK: - Albums

    /// Fetch options for an album. Hidden assets and shared-album assets are both
    /// excluded from ordinary fetches, so each needs opting into explicitly.
    nonisolated static func fetchOptions(includesHidden: Bool, sorted: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        if sorted {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        if includesHidden { options.includeHiddenAssets = true }
        return options
    }

    func loadAlbums() {
        // Counting 77 collections is a quarter second of PhotoKit queries. It is a pure
        // read pass, so it has no business holding the main actor while the sidebar and
        // the grid are trying to draw.
        albumLoadTask?.cancel()
        albumLoadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Log.measure("loadAlbums.enumerate") { PhotoStore.enumerateAlbums() }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.albumGroups = snapshot.groups
            self.albums = snapshot.groups.flatMap(\.albums)
            let (albumCount, groupCount) = (self.albums.count, snapshot.groups.count)
            Log.library.notice("loaded \(albumCount, privacy: .public) albums in \(groupCount, privacy: .public) groups")
            if self.selectedAlbum == nil { self.select(self.albums.first) }
        }
    }

    nonisolated private static func enumerateAlbums() -> AlbumSnapshot {
        var groups: [AlbumGroup] = []

        // --- Library ---
        groups.append(AlbumGroup(id: "library", title: "Library", albums: [
            Album(id: "__all__", title: "All Photos",
                  count: PHAsset.fetchAssets(with: nil).count,
                  symbol: "photo.on.rectangle.angled", collection: nil)
        ]))

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

        // --- Utilities, last ---
        // Hidden is a real smart album (subtype 205); Recently Deleted is not a
        // collection at all and is synthesised here. Both usually read "—" because
        // macOS withholds them, so they sit at the bottom rather than directly under
        // All Photos, where two dashes read as something being broken.
        var utilities: [Album] = []
        let hiddenOptions = PHFetchOptions()
        hiddenOptions.includeHiddenAssets = true
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                subtype: .smartAlbumAllHidden,
                                                options: nil)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: hiddenOptions).count
                utilities.append(Album(id: collection.localIdentifier,
                                       title: collection.localizedTitle ?? "Hidden",
                                       count: count,
                                       symbol: "eye.slash",
                                       collection: collection,
                                       includesHidden: true,
                                       notice: count == 0 ? .hiddenLocked : nil))
            }
        utilities.append(Album(id: "__recently_deleted__", title: "Recently Deleted",
                               count: 0, symbol: "trash.slash", collection: nil,
                               notice: .recentlyDeleted))
        groups.append(AlbumGroup(id: "utilities", title: "Utilities", albums: utilities))

        return AlbumSnapshot(groups: groups)
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

        // The fetch runs off the main actor. It is most of a second for a 35,000-asset
        // library, and doing it here meant the window could not draw -- not just this
        // view, the window itself -- until it finished.
        isLoading = true
        selectGeneration &+= 1
        let generation = selectGeneration
        let source = CollectionRef(collection: album.collection)
        let includesHidden = album.includesHidden

        selectTask?.cancel()
        selectTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                Log.measure("select.fetch") {
                    let options = PhotoStore.fetchOptions(includesHidden: includesHidden,
                                                          sorted: true)
                    let result = source.collection
                        .map { PHAsset.fetchAssets(in: $0, options: options) }
                        ?? PHAsset.fetchAssets(with: options)
                    let loaded = result.count == 0
                        ? []
                        : result.objects(at: IndexSet(0..<result.count))
                    return AssetBatch(fetch: result,
                                      assets: loaded,
                                      downloadable: expandingBursts(loaded))
                }
            }.value

            // A newer selection may have started while this one was in flight, and its
            // result must win however the two finish.
            guard let self, !Task.isCancelled, self.selectGeneration == generation else { return }
            self.currentFetch = batch.fetch
            self.assets = batch.assets
            self.downloadableAssets = batch.downloadable
            self.imageManager.stopCachingImagesForAllAssets()
            Log.measure("select.rebuildSections") { self.rebuildSections() }
            self.isLoading = false
        }
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

        let updated = details.fetchResultAfterChanges
        currentFetch = updated
        let inserted = details.insertedObjects.count
        let carrier = FetchRef(fetch: updated)

        // Same reasoning as the initial load: rebuilding 35,000 assets is most of a
        // second, and a download makes the library change constantly, so doing it here
        // would jank the grid for the entire run.
        selectTask?.cancel()
        selectTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                Log.measure("change.rematerialise") {
                    let loaded = carrier.fetch.count == 0
                        ? []
                        : carrier.fetch.objects(at: IndexSet(0..<carrier.fetch.count))
                    return AssetBatch(fetch: carrier.fetch,
                                      assets: loaded,
                                      downloadable: expandingBursts(loaded))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.assets = batch.assets
            self.downloadableAssets = batch.downloadable

            // Selection is held by identifier, so it survives a reload -- drop only the
            // entries whose photo genuinely went away. Wiping it here would be maddening
            // for someone half way through picking a few hundred photos.
            self.selection.formIntersection(Set(batch.assets.map(\.localIdentifier)))

            self.rebuildSections()
            self.arrivedSinceOpen += inserted
            self.libraryVersion += 1
        }

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
