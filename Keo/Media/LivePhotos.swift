import Foundation

/// An iPhone Live Photo copied to a NAS arrives as two ordinary files: `IMG_4821.HEIC` and
/// `IMG_4821.MOV`, same stem, same folder. Nothing in the files says they belong together —
/// the pairing iOS does through `PHAsset` metadata is lost the moment they are copied.
///
/// So a library of Live Photos looks twice as full as it is, and every photo has a silent
/// grey twin next to it in the grid. This reunites them on the only evidence left: the name.
///
/// Pure on purpose. The same rule has to hold in three places — a fresh listing from the box,
/// a listing replayed from the index, and the SQL that marks the index — and a rule that
/// drifts between them shows a video in one and hides it in the other.
enum LivePhotos {
    /// Everything before the last dot. `IMG_4821.HEIC` and `IMG_4821.MOV` share `IMG_4821`.
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }

    /// Case-folded: a NAS can hold `IMG_4821.HEIC` next to `img_4821.mov`, and SMB shares are
    /// usually case-insensitive anyway.
    static func key(_ name: String) -> String { stem(name).lowercased() }

    /// Splits a folder's media into what the grid shows and what hides behind it.
    ///
    /// A video is a companion only when a *still* of the same stem sits in the same folder.
    /// A lone `.MOV` is a video like any other and stays visible — that is the common case
    /// for anything not shot on an iPhone, and hiding it would lose it altogether.
    static func pair(_ media: [Item]) -> (visible: [Item], companions: [Item.ID: Item]) {
        let stills = media.filter { $0.kind == .image }
        guard !stills.isEmpty else { return (media, [:]) }

        var stillByKey: [String: Item] = [:]
        for still in stills {
            // First wins, so the pairing does not depend on the sort order of the listing.
            stillByKey[key(still.name)] = stillByKey[key(still.name)] ?? still
        }

        var companions: [Item.ID: Item] = [:]
        var visible: [Item] = []
        visible.reserveCapacity(media.count)
        for item in media {
            guard item.kind == .video, let still = stillByKey[key(item.name)] else {
                visible.append(item)
                continue
            }
            companions[still.id] = item
        }
        return (visible, companions)
    }
}
