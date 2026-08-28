import Foundation
import Photos

/// Assert-based check for the pure logic in ResourcePlan.swift.
/// Run with:  ./run.sh --self-check
enum SelfCheck {
    static func run() -> Never {
        // --- Unedited photo: just the original. ---
        check(planResources(types: [.photo], includeUnmodifiedOriginals: false),
              [PlannedResource(index: 0, role: .primary)],
              "plain photo -> primary only")

        // --- Unedited photo, originals requested: no duplicate, original IS primary. ---
        check(planResources(types: [.photo], includeUnmodifiedOriginals: true),
              [PlannedResource(index: 0, role: .primary)],
              "plain photo + originals -> still one file, not two")

        // --- Edited photo: primary must be the rendered version, not the original. ---
        check(planResources(types: [.photo, .fullSizePhoto, .adjustmentData],
                            includeUnmodifiedOriginals: false),
              [PlannedResource(index: 1, role: .primary)],
              "edited photo -> keeps the edit, drops adjustment blob")

        // --- Edited photo, originals requested: both, original suffixed. ---
        check(planResources(types: [.photo, .fullSizePhoto], includeUnmodifiedOriginals: true),
              [PlannedResource(index: 1, role: .primary),
               PlannedResource(index: 0, role: .unmodifiedOriginal)],
              "edited photo + originals -> two files")

        // --- Live Photo: still + motion. ---
        check(planResources(types: [.photo, .pairedVideo], includeUnmodifiedOriginals: false),
              [PlannedResource(index: 0, role: .primary),
               PlannedResource(index: 1, role: .livePhotoVideo)],
              "live photo -> still + paired video")

        // --- Edited Live Photo prefers both full-size halves. ---
        check(planResources(types: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo],
                            includeUnmodifiedOriginals: false),
              [PlannedResource(index: 2, role: .primary),
               PlannedResource(index: 3, role: .livePhotoVideo)],
              "edited live photo -> full-size halves")

        // --- RAW+JPEG: never drop the RAW. ---
        check(planResources(types: [.photo, .alternatePhoto], includeUnmodifiedOriginals: false),
              [PlannedResource(index: 0, role: .primary),
               PlannedResource(index: 1, role: .rawAlternate)],
              "raw+jpeg -> keeps both")

        // --- Video. ---
        check(planResources(types: [.video, .fullSizeVideo], includeUnmodifiedOriginals: false),
              [PlannedResource(index: 1, role: .primary)],
              "edited video -> rendered version")

        // --- Filenames ---
        expect(applySuffix("IMG_1.HEIC", "_original") == "IMG_1_original.HEIC", "suffix before ext")
        expect(applySuffix("IMG_1.HEIC", "") == "IMG_1.HEIC", "empty suffix is a no-op")
        expect(applySuffix("noext", "_original") == "noext_original", "suffix with no extension")
        expect(sanitizeFilename("a/b:c.jpg") == "a_b_c.jpg", "path separators stripped")
        expect(sanitizeFilename("../../etc/passwd") == ".._.._etc_passwd", "no directory escape")
        expect(sanitizeFilename("   ") == "unnamed", "blank name replaced")

        let date = Date(timeIntervalSince1970: 1_710_000_000) // 2024-03-09 UTC
        let path = relativePath(creationDate: date, filename: "IMG_1.HEIC",
                                role: .primary, layout: .dateFolders)
        expect(path.hasSuffix("/IMG_1.HEIC"), "path ends with filename")
        expect(path.hasPrefix("2024/2024-03-0"), "path is year/date foldered, got \(path)")
        expect(relativePath(creationDate: nil, filename: "x.jpg",
                            role: .primary, layout: .dateFolders) == "Undated/x.jpg",
               "nil date -> Undated")

        // Flat layout: no folders at all, and the role suffix still applies.
        expect(relativePath(creationDate: date, filename: "IMG_1.HEIC",
                            role: .primary, layout: .flat) == "IMG_1.HEIC",
               "flat layout drops the date folders")
        expect(relativePath(creationDate: nil, filename: "x.jpg",
                            role: .primary, layout: .flat) == "x.jpg",
               "flat layout has no Undated folder")
        expect(relativePath(creationDate: date, filename: "IMG_1.HEIC",
                            role: .unmodifiedOriginal, layout: .flat) == "IMG_1_original.HEIC",
               "flat layout still suffixes the pre-edit original")
        expect(!relativePath(creationDate: date, filename: "a/b.jpg",
                             role: .primary, layout: .flat).contains("/"),
               "flat layout can never introduce a subfolder")

        // --- Collision handling ---
        let root = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.jpg", "/tmp/x/a (2).jpg"]
        let free = uniqueURL(root.appendingPathComponent("a.jpg")) { taken.contains($0.path) }
        expect(free.lastPathComponent == "a (3).jpg", "collides up to a free slot, got \(free.lastPathComponent)")
        let untouched = uniqueURL(root.appendingPathComponent("b.jpg")) { taken.contains($0.path) }
        expect(untouched.lastPathComponent == "b.jpg", "free name is left alone")

        checkDatePrefix()
        checkFinderTags()
        checkTimestamps()
        checkIncremental()
        checkScanner()
        checkGrouping()

        print("\nself-check: all \(passed) assertions passed")
        exit(0)
    }

    // MARK: - Date-prefixed filenames

    private static func checkDatePrefix() {
        let date = Date(timeIntervalSince1970: 1_710_000_000)   // 2024-03-09 (local)
        let stamp = { () -> String in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }()

        let dated = relativePath(creationDate: date, filename: "IMG_1.HEIC",
                                 role: .primary, layout: .flat, datePrefix: true)
        expect(dated == "\(stamp) IMG_1.HEIC", "flat + prefix, got \(dated)")

        let foldered = relativePath(creationDate: date, filename: "IMG_1.HEIC",
                                    role: .primary, layout: .dateFolders, datePrefix: true)
        expect(foldered.hasSuffix("/\(stamp) IMG_1.HEIC"),
               "date folders + prefix, got \(foldered)")

        // The real motivation: UUID names become sortable.
        let uuid = relativePath(creationDate: date,
                                filename: "488ECD3E-3C17-467B-B85B-FAFE7461DEE8.mp4",
                                role: .primary, layout: .flat, datePrefix: true)
        expect(uuid.hasPrefix(stamp), "UUID filenames get a readable date in front")

        // Never stamp twice when the name already starts with that date.
        let already = relativePath(creationDate: date, filename: "\(stamp) IMG_1.HEIC",
                                   role: .primary, layout: .flat, datePrefix: true)
        expect(already == "\(stamp) IMG_1.HEIC", "no double stamp, got \(already)")

        // No date to stamp with -> leave the name alone.
        expect(relativePath(creationDate: nil, filename: "x.jpg",
                            role: .primary, layout: .flat, datePrefix: true) == "x.jpg",
               "undated asset keeps its plain name")

        // Off by default -> unchanged.
        expect(relativePath(creationDate: date, filename: "IMG_1.HEIC",
                            role: .primary, layout: .flat) == "IMG_1.HEIC",
               "prefix is opt-in")

        // Suffix and prefix coexist.
        let both = relativePath(creationDate: date, filename: "IMG_1.HEIC",
                                role: .unmodifiedOriginal, layout: .flat, datePrefix: true)
        expect(both == "\(stamp) IMG_1_original.HEIC", "prefix + suffix, got \(both)")
    }

    // MARK: - Finder tags

    private static func checkFinderTags() {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icg-tags-\(UUID().uuidString).jpg")
        fm.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? fm.removeItem(at: url) }

        applyFinderTags(to: url, tags: ["Summer Trip", "Favorite", "Summer Trip"])
        let read = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames
        expect(read?.sorted() == ["Favorite", "Summer Trip"],
               "tags written and de-duplicated, got \(read ?? [])")

        // Finder reads them from this attribute -- confirm it is really there.
        let size = getxattr(url.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
        expect(size > 0, "the extended attribute Finder reads exists")

        // No tags must not clear or touch anything.
        applyFinderTags(to: url, tags: [])
        let after = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames
        expect(after?.sorted() == ["Favorite", "Summer Trip"],
               "an empty tag list is a no-op, not a wipe")
    }

    // MARK: - File timestamps

    private static func checkTimestamps() {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icg-stamp-\(UUID().uuidString).jpg")
        fm.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? fm.removeItem(at: url) }

        let taken = Date(timeIntervalSince1970: 1_592_920_000)   // 2020-06-23
        applyTimestamps(to: url, creationDate: taken)

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let ctime = attrs?[.creationDate] as? Date
        expect(abs((mtime?.timeIntervalSince1970 ?? 0) - taken.timeIntervalSince1970) < 1,
               "modification date is the capture date, not the download time")
        expect(abs((ctime?.timeIntervalSince1970 ?? 0) - taken.timeIntervalSince1970) < 1,
               "creation date is the capture date")

        // An asset with no date must leave the file alone rather than stamp 1970.
        let before = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        applyTimestamps(to: url, creationDate: nil)
        let after = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        expect(before == after, "a nil capture date leaves timestamps untouched")
    }

    // MARK: - Incremental download

    private static func checkIncremental() {
        let existing: Set<String> = ["2024/2024-03-15/IMG_1.HEIC"]

        // Ledger knows the asset -> nothing to do, and `planned` is never evaluated.
        var plannedWasCalled = false
        let done = missingPaths(recorded: ["2024/2024-03-15/IMG_1.HEIC"],
                                planned: { plannedWasCalled = true; return ["x"] }(),
                                existing: existing)
        expect(done.isEmpty, "ledger hit -> nothing missing")
        expect(!plannedWasCalled, "fast path must not query PhotoKit")

        // No ledger entry, file already there -> treat as done (legacy fallback).
        expect(missingPaths(recorded: [],
                            planned: ["2024/2024-03-15/IMG_1.HEIC"],
                            existing: existing).isEmpty,
               "fallback matches an existing filename")

        // No ledger entry, file absent -> needs download.
        expect(missingPaths(recorded: [],
                            planned: ["2024/2024-03-15/IMG_9.HEIC"],
                            existing: existing) == ["2024/2024-03-15/IMG_9.HEIC"],
               "fallback reports a genuinely missing file")

        // THE COLLISION CASE. Two different photos, both named IMG_1.HEIC, same day.
        // Filename matching alone says the second is already downloaded -- it is not.
        let bothOnDisk: Set<String> = ["2024/2024-03-15/IMG_1.HEIC",
                                       "2024/2024-03-15/IMG_1 (2).HEIC"]
        expect(missingPaths(recorded: [], planned: ["2024/2024-03-15/IMG_1.HEIC"],
                            existing: bothOnDisk).isEmpty,
               "without a ledger, photo B is wrongly considered present")
        expect(missingPaths(recorded: ["2024/2024-03-15/IMG_1 (2).HEIC"],
                            planned: ["2024/2024-03-15/IMG_1.HEIC"],
                            existing: bothOnDisk).isEmpty,
               "with a ledger, photo B is correctly matched to its own file")

        checkLedgerRoundTrip()
        checkRunLog()
    }

    private static func checkLedgerRoundTrip() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icloudgui-selfcheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var ledger = DownloadLedger(destination: dir)
        expect(ledger.paths(for: "A").isEmpty, "fresh ledger is empty")
        ledger.record(assetID: "A", relativePath: "2024/2024-03-15/IMG_1.HEIC")
        ledger.record(assetID: "A", relativePath: "2024/2024-03-15/IMG_1.MOV")   // live photo
        ledger.record(assetID: "B", relativePath: "2024/2024-03-15/IMG_1 (2).HEIC")
        ledger.flush()

        let reloaded = DownloadLedger(destination: dir)
        expect(reloaded.paths(for: "A").count == 2, "both halves of a Live Photo survive a reload")
        expect(reloaded.paths(for: "B") == ["2024/2024-03-15/IMG_1 (2).HEIC"],
               "the disambiguated path is what gets recorded")

        // Pruning: pretend B's file was deleted from the NAS.
        var pruned = DownloadLedger(destination: dir)
        pruned.prune(keeping: ["2024/2024-03-15/IMG_1.HEIC", "2024/2024-03-15/IMG_1.MOV"])
        expect(pruned.paths(for: "B").isEmpty, "row for a deleted file is dropped")
        expect(pruned.paths(for: "A").count == 2, "rows for surviving files are kept")
        expect(DownloadLedger(destination: dir).paths(for: "B").isEmpty,
               "prune is persisted, not just in memory")
        expect(missingPaths(recorded: pruned.paths(for: "B"),
                            planned: ["2024/2024-03-15/IMG_1 (2).HEIC"],
                            existing: ["2024/2024-03-15/IMG_1.HEIC"])
               == ["2024/2024-03-15/IMG_1 (2).HEIC"],
               "a deleted photo is re-fetched after pruning")
    }

    private static func checkRunLog() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icg-log-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let log = RunLog(destination: dir)
        log.started(items: 1200, options: "dateFolders tags")
        log.failed(filename: "IMG_1.HEIC", assetID: "ABC-123", reason: "Network unavailable")
        log.failed(filename: "IMG_2.MOV", assetID: "DEF-456", reason: "Timed out")
        log.finished("Downloaded 1198 items · 2 failed.")

        let text = (try? String(contentsOf: dir.appendingPathComponent(RunLog.filename),
                                encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        expect(lines.count == 4, "one line per event, got \(lines.count)")
        expect(text.contains("RUN START"), "run start recorded")
        expect(text.contains("RUN END"), "run end recorded")

        // The point of the file: which items failed, and why, survives quitting.
        expect(text.contains("IMG_1.HEIC") && text.contains("Network unavailable"),
               "failed filename and reason are both recorded")
        expect(text.contains("ABC-123"),
               "the asset identifier is recorded, so a failure can be traced back")
        expect(lines.filter { $0.contains("FAILED") }.count == 2, "both failures recorded")

        // Appends across runs rather than truncating -- history matters for a backup.
        RunLog(destination: dir).started(items: 5, options: "flat")
        let after = (try? String(contentsOf: dir.appendingPathComponent(RunLog.filename),
                                 encoding: .utf8)) ?? ""
        expect(after.split(separator: "\n").count == 5,
               "a second run appends rather than truncating")
        expect(after.contains("IMG_1.HEIC"), "earlier failures are not lost")
    }

    // MARK: - Destination scanner

    private static func checkScanner() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icloudgui-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        func make(_ relative: String) {
            let url = root.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        make("2024/2024-03-15/IMG_1.HEIC")
        make("2024/2024-03-15/IMG_1.MOV")
        make("2023/2023-01-02/IMG_9.JPG")
        make("2024/2024-03-15/IMG_2.HEIC.part")   // interrupted -- must not count
        make(".icloudgui-index.tsv")              // our own ledger -- hidden, skipped

        let found = DestinationScanner.scan(root: root) { _ in }

        expect(found.contains("2024/2024-03-15/IMG_1.HEIC"), "finds a nested file by relative path")
        expect(found.contains("2023/2023-01-02/IMG_9.JPG"), "finds files in other year folders")
        expect(found.count == 3, "counts exactly the 3 real files, got \(found.count): \(found.sorted())")
        expect(!found.contains { $0.hasSuffix(".part") }, "a .part file is never treated as present")
        expect(!found.contains { $0.hasPrefix(".") }, "hidden files are skipped")

        // Paths must be relative -- an absolute path here would break every ledger lookup.
        expect(!found.contains { $0.hasPrefix("/") }, "paths are relative, not absolute")

        // A trailing slash on the root must not shift the prefix math.
        let withSlash = DestinationScanner.scan(
            root: URL(fileURLWithPath: root.path + "/")) { _ in }
        expect(withSlash == found, "trailing slash on root gives identical results")

        expect(DestinationScanner.scan(
            root: root.appendingPathComponent("does-not-exist")) { _ in }.isEmpty,
            "missing destination scans to empty rather than crashing")
    }

    // MARK: - Date grouping

    private static func checkGrouping() {
        func date(_ s: String) -> Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f.date(from: s)!
        }

        expect(groupKey(date("2024-03-05"), .day) == "2024-03-05", "day key is zero padded")
        expect(groupKey(date("2024-03-05"), .month) == "2024-03", "month key")
        expect(groupKey(date("2024-03-05"), .year) == "2024", "year key")
        expect(groupKey(nil, .day).isEmpty, "undated key is empty")

        let dates: [Date?] = [date("2024-03-05"), date("2024-03-05"),
                              date("2024-03-04"), date("2024-01-09"), nil]

        let byDay = groupConsecutive(dates: dates, grouping: .day)
        expect(byDay.count == 4, "four distinct days, got \(byDay.count)")
        expect(byDay[0].range == 0..<2, "the two same-day photos group together")
        expect(byDay[3].range == 4..<5, "undated lands in its own group")

        let byMonth = groupConsecutive(dates: dates, grouping: .month)
        expect(byMonth.count == 3, "March, January, undated -> 3, got \(byMonth.count)")
        expect(byMonth[0].range == 0..<3, "all of March collapses into one run")

        let byYear = groupConsecutive(dates: dates, grouping: .year)
        expect(byYear.count == 2, "2024 + undated, got \(byYear.count)")
        expect(byYear[0].range == 0..<4, "the whole year is one run")

        expect(groupConsecutive(dates: [], grouping: .day).isEmpty, "empty input is safe")
        expect(groupLabel(nil, .day) == "Undated", "nil date labels as Undated")
        expect(groupLabel(date("2024-03-05"), .year) == "2024", "year label")

        // Grouping must never lose or duplicate an asset.
        let covered = byDay.reduce(0) { $0 + $1.range.count }
        expect(covered == dates.count, "day groups cover every asset exactly once")

        checkAlbumFilter()
        checkVersionCompare()
    }

    // MARK: - Sidebar filter

    private static func checkAlbumFilter() {
        func album(_ title: String) -> Album {
            Album(id: title, title: title, count: 1, symbol: "", collection: nil)
        }
        let groups = [
            AlbumGroup(id: "library", title: "Library", albums: [album("All Photos")]),
            AlbumGroup(id: "mine", title: "My Albums",
                       albums: [album("Beach"), album("Beach Trip"), album("Garden")]),
        ]

        expect(filterAlbums(groups, matching: "").count == 2, "empty query filters nothing")
        expect(filterAlbums(groups, matching: "   ").count == 2,
               "whitespace-only query filters nothing")

        let beach = filterAlbums(groups, matching: "beach")
        // The Library section matched nothing, so it must not survive as a bare heading.
        expect(beach.count == 1, "sections with no match are dropped")
        expect(beach.first?.albums.map(\.title) == ["Beach", "Beach Trip"],
               "case-insensitive substring match, order preserved")

        expect(filterAlbums(groups, matching: "  Garden ").first?.albums.count == 1,
               "query is trimmed before matching")
        expect(filterAlbums(groups, matching: "zzz").isEmpty, "no matches yields no sections")
    }

    // MARK: - Update check

    private static func checkVersionCompare() {
        expect(Updates.normalise("v1.2") == "1.2", "leading v is stripped from a tag")
        expect(Updates.normalise(" 1.2 ") == "1.2", "surrounding whitespace is stripped")

        expect(Updates.isNewer("v1.3", than: "1.2"), "1.3 is newer than 1.2")
        expect(!Updates.isNewer("v1.2", than: "1.2"), "the same version is not newer")
        expect(!Updates.isNewer("v1.1", than: "1.2"), "an older tag is not newer")

        // The comparison a plain string compare gets backwards, and the reason this is
        // worth asserting at all: it only starts mattering at the tenth release.
        expect(Updates.isNewer("v1.10", than: "1.9"), "1.10 is newer than 1.9")
        expect(!Updates.isNewer("v1.9", than: "1.10"), "1.9 is not newer than 1.10")
        expect(Updates.isNewer("v2.0", than: "1.99"), "2.0 is newer than 1.99")

        // A local build ahead of the published release must not be told to downgrade.
        expect(!Updates.isNewer("v1.2", than: "1.3"), "a dev build ahead of release is up to date")
    }

    private static var passed = 0

    private static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
        } else {
            print("FAIL: \(label)")
            exit(1)
        }
    }

    private static func check(_ got: [PlannedResource], _ want: [PlannedResource], _ label: String) {
        expect(got == want, "\(label)\n  want: \(want)\n  got:  \(got)")
    }
}
