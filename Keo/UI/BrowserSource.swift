import Foundation

/// What a grid is showing. A folder on the NAS, or one of the local collections the app keeps
/// for itself — they share the same grid, sections, viewer, selection and download machinery.
enum BrowserSource: Hashable, Identifiable {
    case folder(path: String, title: String)
    case favourites
    case collection(id: Int64, name: String)

    var id: String {
        switch self {
        case .folder(let path, _): return "folder:\(path)"
        case .favourites: return "favourites"
        case .collection(let id, _): return "collection:\(id)"
        }
    }

    var title: String {
        switch self {
        case .folder(_, let title): return title
        case .favourites: return "Favoris"
        case .collection(_, let name): return name
        }
    }

    /// `nil` for the local collections: there is nothing to ask the box about.
    var folderPath: String? {
        if case .folder(let path, _) = self { return path }
        return nil
    }

    var isRoot: Bool { folderPath == FreeboxClient.rootPath }

    /// Indexing, listing caches and folder statistics only mean something for a real folder.
    var isOnNAS: Bool { folderPath != nil }

    static func folder(_ item: Item) -> BrowserSource {
        .folder(path: item.path, title: item.name)
    }
}
