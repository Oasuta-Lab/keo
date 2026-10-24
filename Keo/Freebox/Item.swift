import Foundation

/// One entry on the NAS. Pure value type: no reference to the client that produced it,
/// so it is cheap to copy across a large listing and safe to hand between tasks.
struct Item: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let mimeType: String?

    var id: String { path }

    enum Kind: Sendable { case folder, image, video, other }

    /// Computed once at construction: a listing of 20 000 entries would otherwise re-derive
    /// this on every filter pass and every view update.
    let kind: Kind

    var isMedia: Bool { kind == .image || kind == .video }

    init(path: String, name: String, isDirectory: Bool, size: Int64,
         modified: Date?, mimeType: String?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.mimeType = mimeType
        self.kind = Self.classify(path: path, isDirectory: isDirectory, mimeType: mimeType)
    }

    static func == (a: Item, b: Item) -> Bool { a.path == b.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    private static func classify(path: String, isDirectory: Bool, mimeType: String?) -> Kind {
        if isDirectory { return .folder }
        if let mimeType {
            if mimeType.hasPrefix("image/") { return .image }
            if mimeType.hasPrefix("video/") { return .video }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return .other
    }

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
    private static let videoExtensions: Set<String> =
        ["mp4", "mov", "m4v", "avi", "mkv", "hevc", "mpg", "mpeg", "3gp", "webm"]
}

/// A folder, already split by kind. Built once per load instead of being re-filtered on
/// every SwiftUI body evaluation — the single biggest source of jank on a large folder.
struct FolderContents: Sendable {
    let folders: [Item]
    let media: [Item]
    let documents: [Item]

    static let empty = FolderContents(folders: [], media: [], documents: [])

    var isEmpty: Bool { folders.isEmpty && media.isEmpty && documents.isEmpty }
    var selectableCount: Int { media.count + documents.count }
    /// Grid order, so a selection can be replayed in the order the user sees.
    var selectable: [Item] { media + documents }

    init(folders: [Item], media: [Item], documents: [Item]) {
        self.folders = folders
        self.media = media
        self.documents = documents
    }

    init(_ items: [Item]) {
        var folders: [Item] = []
        var media: [Item] = []
        var documents: [Item] = []
        folders.reserveCapacity(items.count / 4)
        media.reserveCapacity(items.count)

        for item in items {
            switch item.kind {
            case .folder: folders.append(item)
            case .image, .video: media.append(item)
            case .other: documents.append(item)
            }
        }
        self.init(folders: folders, media: media, documents: documents)
    }
}
