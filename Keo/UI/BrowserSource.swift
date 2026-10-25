import Foundation

/// What a grid is showing. A folder on the NAS, or one of the local collections the app keeps
/// for itself — they share the same grid, sections, viewer, selection and download machinery.
enum BrowserSource: Hashable, Identifiable {
    case folder(path: String, title: String)
    case favourites
    case collection(id: Int64, name: String)
    /// Already-resolved items, handed over rather than fetched — search results.
    case results(title: String, items: [Item])

    var id: String {
        switch self {
        case .folder(let path, _): return "folder:\(path)"
        case .favourites: return "favourites"
        case .collection(let id, _): return "collection:\(id)"
        // Must change with the items, or the grid keeps the previous search.
        case .results(_, let items): return "results:\(items.hashValue)"
        }
    }

    var title: String {
        switch self {
        case .folder(_, let title): return title
        case .favourites: return "Favoris"
        case .collection(_, let name): return name
        case .results(let title, _): return title
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

    /// The folder an item sits in. `nil` only when there is nothing to go to — the item is
    /// already at the root, or its path is not one we can split. Never a made-up folder.
    static func parent(of item: Item) -> BrowserSource? {
        var components = item.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        components.removeLast()
        guard let name = components.last else { return nil }
        return .folder(path: "/" + components.joined(separator: "/"), title: name)
    }

    static func folder(_ item: Item) -> BrowserSource {
        .folder(path: item.path, title: item.name)
    }
}

/// The chain of folders from the root down to this one, for a breadcrumb.
///
/// Pure, so the splitting can be checked: a NAS path can be deep, can carry accents and
/// spaces, and the root has no name of its own.
enum Breadcrumb {
    struct Crumb: Identifiable, Equatable, Sendable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// Root first, the folder itself last. Empty for anything that is not a NAS folder —
    /// favourites and a collection have no path to climb.
    static func trail(to path: String, rootName: String) -> [Crumb] {
        guard path.hasPrefix("/") else { return [] }
        var crumbs = [Crumb(name: rootName, path: FreeboxClient.rootPath)]
        var walked = ""
        for part in path.split(separator: "/") {
            walked += "/" + part
            crumbs.append(Crumb(name: String(part), path: walked))
        }
        return crumbs
    }
}
