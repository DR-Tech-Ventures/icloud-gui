import Foundation
import Photos

/// Why we are downloading a given resource. Drives filename suffixing.
enum ResourceRole: String {
    case primary              // what the user sees in Photos (edited if edits exist)
    case livePhotoVideo       // the .mov half of a Live Photo
    case rawAlternate         // RAW half of a RAW+JPEG pair
    case unmodifiedOriginal   // pre-edit original, only when the user asks for it

    /// Suffix inserted before the extension so two resources that share an
    /// `originalFilename` (common for edited photos) cannot collide.
    var filenameSuffix: String {
        switch self {
        case .primary, .rawAlternate, .livePhotoVideo: return ""
        case .unmodifiedOriginal: return "_original"
        }
    }
}

struct PlannedResource: Equatable {
    let index: Int          // index into the asset's resource array
    let role: ResourceRole

    static func == (a: PlannedResource, b: PlannedResource) -> Bool {
        a.index == b.index && a.role == b.role
    }
}

/// Decides which of an asset's resources to write to disk.
///
/// PhotoKit hands back every derivative it has: the original, the rendered
/// post-edit version, adjustment blobs, Live Photo pairs, RAW alternates.
/// Downloading all of them wastes space; downloading only `.photo` silently
/// discards the user's edits. This picks the set a backup should actually keep.
func planResources(
    types: [PHAssetResourceType],
    includeUnmodifiedOriginals: Bool
) -> [PlannedResource] {
    func firstIndex(of type: PHAssetResourceType) -> Int? {
        types.firstIndex(of: type)
    }

    var plan: [PlannedResource] = []

    // Primary: prefer the rendered full-size version, which exists only when edited.
    let editedPhoto = firstIndex(of: .fullSizePhoto)
    let editedVideo = firstIndex(of: .fullSizeVideo)
    let rawPhoto = firstIndex(of: .photo)
    let rawVideo = firstIndex(of: .video)

    if let i = editedPhoto ?? rawPhoto {
        plan.append(PlannedResource(index: i, role: .primary))
    }
    if let i = editedVideo ?? rawVideo {
        plan.append(PlannedResource(index: i, role: .primary))
    }

    // Live Photo motion component, edited version preferred.
    if let i = firstIndex(of: .fullSizePairedVideo) ?? firstIndex(of: .pairedVideo) {
        plan.append(PlannedResource(index: i, role: .livePhotoVideo))
    }

    // RAW half of a RAW+JPEG pair. Always kept -- dropping it loses real data.
    if let i = firstIndex(of: .alternatePhoto) {
        plan.append(PlannedResource(index: i, role: .rawAlternate))
    }

    guard includeUnmodifiedOriginals else { return plan }

    // Only meaningful when an edit exists; otherwise the original *is* the primary.
    if editedPhoto != nil, let i = rawPhoto {
        plan.append(PlannedResource(index: i, role: .unmodifiedOriginal))
    }
    if editedVideo != nil, let i = rawVideo {
        plan.append(PlannedResource(index: i, role: .unmodifiedOriginal))
    }
    return plan
}

// MARK: - Filenames

// Tab and newline are stripped so a filename can never corrupt a ledger row.
private let illegalFilenameChars = CharacterSet(charactersIn: "/:\0\t\n\r")

/// Strips path separators so a hostile or odd `originalFilename` cannot escape
/// the destination directory.
func sanitizeFilename(_ name: String) -> String {
    let cleaned = name.components(separatedBy: illegalFilenameChars).joined(separator: "_")
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "unnamed" }
    return trimmed
}

/// Inserts `suffix` before the file extension: ("IMG_1.HEIC", "_original") -> "IMG_1_original.HEIC"
func applySuffix(_ filename: String, _ suffix: String) -> String {
    guard !suffix.isEmpty else { return filename }
    let ext = (filename as NSString).pathExtension
    guard !ext.isEmpty else { return filename + suffix }
    let base = (filename as NSString).deletingPathExtension
    return "\(base)\(suffix).\(ext)"
}

/// How downloaded files are arranged inside the destination.
enum FolderLayout: String, CaseIterable, Identifiable {
    case dateFolders   // 2024/2024-03-15/IMG_1234.HEIC
    case flat          // IMG_1234.HEIC

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dateFolders: return "Date folders"
        case .flat: return "One folder"
        }
    }
    var detail: String {
        switch self {
        case .dateFolders: return "2024/2024-03-15/IMG_1234.HEIC"
        case .flat: return "IMG_1234.HEIC — everything in the destination folder"
        }
    }
}

/// Prefix for filenames when the user asks for it. Roughly 8% of a real library comes
/// back from PhotoKit named like `488ECD3E-3C17-467B-B85B-FAFE7461DEE8.mp4` -- a date
/// in front is the difference between a browsable folder and a wall of UUIDs.
private let filePrefixFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}()

private let folderFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}()

/// Relative path under the destination root.
///
/// Date folders keep directories small; a flat layout puts everything side by side,
/// which is what some NAS photo indexers expect. Same-name collisions are far more
/// likely when flat, and are resolved by `uniqueURL` plus the ledger, which records
/// the name actually used so repeat runs stay stable.
func relativePath(creationDate: Date?,
                  filename: String,
                  role: ResourceRole,
                  layout: FolderLayout,
                  datePrefix: Bool = false) -> String {
    var name = applySuffix(sanitizeFilename(filename), role.filenameSuffix)
    if datePrefix, let creationDate {
        let stamp = filePrefixFormatter.string(from: creationDate)
        // Never double-stamp a name that already starts with the same date.
        if !name.hasPrefix(stamp) { name = "\(stamp) \(name)" }
    }
    switch layout {
    case .flat:
        return name
    case .dateFolders:
        let folder = creationDate.map(folderFormatter.string(from:)) ?? "Undated"
        return "\(folder)/\(name)"
    }
}

/// Stamps the file with the date the photo was taken.
///
/// Without this a downloaded file carries the date it was written, so a 2020 photo
/// looks like it was created today. Finder sorting and NAS photo indexers
/// (Synology Photos, Immich, PhotoPrism) commonly key off file mtime, which makes an
/// otherwise correct backup sort into nonsense.
func applyTimestamps(to url: URL, creationDate: Date?) {
    guard let creationDate else { return }
    try? FileManager.default.setAttributes(
        [.creationDate: creationDate, .modificationDate: creationDate],
        ofItemAtPath: url.path)
}

/// Writes Finder tags onto a downloaded file.
///
/// These live in an extended attribute. Local APFS/HFS+ disks handle them natively;
/// SMB shares usually do too, though some store them in AppleDouble `._` sidecars and
/// others reject them outright. A tag that will not stick must never fail a download
/// that otherwise succeeded, so errors are deliberately swallowed.
/// Returns false if tags were requested but could not be written -- a share that
/// rejects extended attributes, most likely. The caller records that rather than
/// letting it pass silently, which is how a broken tagging feature shipped once.
@discardableResult
func applyFinderTags(to url: URL, tags: [String]) -> Bool {
    guard !tags.isEmpty else { return true }
    let names = Array(Set(tags)).sorted()   // stable, de-duplicated

    // Written as the extended attribute Finder itself reads, on every macOS version.
    //
    // URLResourceValues.tagNames gained a setter only in macOS 26, and #available does
    // not help: it is a runtime check, while the setter has to exist in the SDK being
    // compiled against. Gating it still breaks the build on an older toolchain -- which
    // is exactly how CI caught this, having compiled clean on a macOS 27 SDK locally.
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: names, format: .binary, options: 0) else { return false }
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return data.withUnsafeBytes { buffer in
            setxattr(path, "com.apple.metadata:_kMDItemUserTags",
                     buffer.baseAddress, data.count, 0, 0)
        }
    }
    return result == 0
}

/// Appends " (2)", " (3)"... until `isTaken` says the name is free.
/// `isTaken` is injected so the naming rule is testable without touching disk.
func uniqueURL(_ url: URL, isTaken: (URL) -> Bool) -> URL {
    guard isTaken(url) else { return url }
    let dir = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    for n in 2...9999 {
        let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
        let candidate = dir.appendingPathComponent(name)
        if !isTaken(candidate) { return candidate }
    }
    return dir.appendingPathComponent("\(base) (\(UUID().uuidString)).\(ext)")
}
