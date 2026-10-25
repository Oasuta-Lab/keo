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

    /// Filled in once the file's own metadata has been read. On a NAS the modification date is
    /// often the day everything was copied, which makes it useless for a timeline.
    var captureDate: Date?

    /// Number of entries inside, when the box reports it. Free: it is already in the listing.
    let childCount: Int?

    /// What the timeline and the date sort actually use.
    var timelineDate: Date? { captureDate ?? modified }

    var id: String { path }

    enum Kind: Sendable {
        case folder, image, video, other

        /// Stored in the index so a cached listing can be classified without the mime type.
        var code: Int {
            switch self {
            case .folder: return 0
            case .image: return 1
            case .video: return 2
            case .other: return 3
            }
        }

        init?(code: Int) {
            switch code {
            case 0: self = .folder
            case 1: self = .image
            case 2: self = .video
            case 3: self = .other
            default: return nil
            }
        }

        /// Enough for `classify` to land on the same kind again. Deliberately `nil` for
        /// folders: whether something is a directory is decided by `isDirectory`, never by a
        /// mime type, or a mislabelled row turns a photo into a folder you can tap into.
        var mimeHint: String? {
            switch self {
            case .folder, .other: return nil
            case .image: return "image/*"
            case .video: return "video/*"
            }
        }
    }

    /// Computed once at construction: a listing of 20 000 entries would otherwise re-derive
    /// this on every filter pass and every view update.
    let kind: Kind

    var isMedia: Bool { kind == .image || kind == .video }

    init(path: String, name: String, isDirectory: Bool, size: Int64,
         modified: Date?, mimeType: String?, childCount: Int? = nil,
         captureDate: Date? = nil) {
        self.captureDate = captureDate
        self.childCount = childCount
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

/// How a listing is ordered. Stored as a raw String so it can live in `@AppStorage`.
enum ItemOrder: String, CaseIterable, Sendable {
    case newest, oldest, name

    var label: String {
        switch self {
        case .newest: return "Plus récentes d'abord"
        case .oldest: return "Plus anciennes d'abord"
        case .name: return "Par nom"
        }
    }

    var systemImage: String {
        switch self {
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .name: return "textformat"
        }
    }

    /// Files without a modification date sort last rather than pretending to be from 1970.
    func precedes(_ a: Item, _ b: Item) -> Bool {
        switch self {
        case .name:
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .newest, .oldest:
            switch (a.timelineDate, b.timelineDate) {
            case let (first?, second?):
                guard first != second else {
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return self == .newest ? first > second : first < second
            case (nil, nil):
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            }
        }
    }
}

/// A folder, already split by kind. Built once per load instead of being re-filtered on
/// every SwiftUI body evaluation — the single biggest source of jank on a large folder.
struct FolderContents: Sendable {
    let folders: [Item]
    let media: [Item]
    let documents: [Item]
    /// The `.MOV` half of a Live Photo, keyed by the still it belongs to. Kept out of `media`
    /// so the grid shows one tile per moment, and kept here so the viewer can still play it.
    let companions: [Item.ID: Item]

    static let empty = FolderContents(folders: [], media: [], documents: [])

    var isEmpty: Bool { folders.isEmpty && media.isEmpty && documents.isEmpty }

    /// Folds freshly discovered capture dates into the listing and re-sorts.
    func applying(_ dates: [Item.ID: Date], order: ItemOrder) -> FolderContents {
        guard !dates.isEmpty else { return self }
        func enrich(_ items: [Item]) -> [Item] {
            items.map { item in
                guard let date = dates[item.id], item.captureDate != date else { return item }
                var copy = item
                copy.captureDate = date
                return copy
            }
        }
        return FolderContents(folders: folders, media: enrich(media),
                              documents: enrich(documents), companions: companions)
            .reordered(by: order)
    }
    var selectableCount: Int { media.count + documents.count }
    /// Grid order, so a selection can be replayed in the order the user sees.
    var selectable: [Item] { media + documents }

    init(folders: [Item], media: [Item], documents: [Item],
         companions: [Item.ID: Item] = [:]) {
        self.folders = folders
        self.media = media
        self.documents = documents
        self.companions = companions
    }

    /// The video half of a Live Photo, if this still has one.
    func companion(of item: Item) -> Item? { companions[item.id] }

    /// Everything the index must know about, companions included. Hiding a file from the grid
    /// must never hide it from the index: the sweep would delete it, and the viewer would
    /// have no video left to play. It is also the real weight of the folder — a Live Photo's
    /// `.MOV` occupies the NAS whether or not it has a tile.
    var filed: [Item] { media + Array(companions.values) + documents }

    /// Reorders in place rather than refetching: changing the sort is not a network question.
    /// Folders stay alphabetical — a NAS folder's mtime says when it was last written to,
    /// which is rarely what someone means by "the date of these photos".
    func reordered(by order: ItemOrder) -> FolderContents {
        FolderContents(folders: folders,
                       media: media.sorted(by: order.precedes),
                       documents: documents.sorted(by: order.precedes),
                       companions: companions)
    }

    init(_ items: [Item], order: ItemOrder = .newest) {
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
        // A Live Photo's video is folded into its still rather than shown next to it: the
        // pairing iOS held in PHAsset metadata is lost when the files land on a NAS, and
        // without this the grid shows every iPhone photo twice.
        let (visible, companions) = LivePhotos.pair(media)
        self.init(folders: folders.sorted(by: ItemOrder.name.precedes),
                  media: visible.sorted(by: order.precedes),
                  documents: documents.sorted(by: order.precedes),
                  companions: companions)
    }
}
