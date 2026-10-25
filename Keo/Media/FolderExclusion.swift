import Foundation

/// The folders the indexing walk refuses to descend into.
///
/// A NAS that holds dev projects holds `node_modules`, and a single one of those is tens of
/// thousands of files across thousands of directories, not one of which is a photo. Descending
/// into it costs listing requests to the box, rows in SQLite, sweep work at the end of every
/// pass, and it inflates every folder count and weight the browser shows.
///
/// Pure and outside SwiftUI, like `LivePhotos` and `WalkOutcome`, and for the same reason: the
/// rule has to hold in two places — the walk, which must not descend, and the one-pass cleanup
/// of what earlier versions already indexed. A rule that drifts between them leaves rows behind
/// that nothing will ever remove.
///
/// Deliberately short, and it stays short. A folder wrongly excluded is photos the owner
/// silently cannot find; a folder wrongly indexed is a few wasted requests. The costs are not
/// comparable, so a name earns its place here only if no human would give it to a folder of
/// photos. See README, « Ce que la règle n'exclut délibérément pas ».
enum FolderExclusion {
    /// Compared case-folded: an SMB share is case-insensitive, so `NODE_MODULES` and
    /// `node_modules` name the same directory. Same reasoning as `LivePhotos.key`.
    static let names: Set<String> = [
        "node_modules",              // npm — the reason this file exists
        "__pycache__",               // Python bytecode, double-underscored by the interpreter
        "venv",                      // a Python virtualenv; `.venv` falls under the dot rule
        "@eadir",                    // Synology's own thumbnail and index store
        "#recycle",                  // Synology's recycle bin
        "$recycle.bin",              // the Windows recycle bin, as it appears on a share
        "system volume information", // Windows per-volume metadata, written to every share
        "lost+found",                // what fsck puts back, never what someone put there
    ]

    static func excludes(folder name: String) -> Bool {
        // Every dotted name in one line: .git, .svn, .venv, .build, .gradle, .next, .tox,
        // .Trash, .Trashes, .Spotlight-V100, .fseventsd, .DocumentRevisions-V100, ._* and
        // .DS_Store. `FreeboxClient.listPage` already drops these before the walk ever sees
        // them; saying it here too is what lets the cleanup reach rows written by an older
        // build, and what keeps this type the single answer to "does Keo index this folder".
        if name.hasPrefix(".") { return true }
        return names.contains(name.lowercased())
    }

    /// True when **any** component of the path is excluded — what the cleanup has to ask of a
    /// row indexed before the rule existed, since only its path survives.
    static func excludes(path: String) -> Bool {
        path.split(separator: "/").contains { excludes(folder: String($0)) }
    }
}
