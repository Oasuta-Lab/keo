import CryptoKit
import Foundation

/// What the app leaves in the shared container, and the only thing the widget ever reads.
///
/// The widget does not open the index. The index holds no pixels — `(folder_id, name, size,
/// capture, read, kind, gen)`, paths and dates — so sharing it would buy the extension a
/// filename and a blur. Worse, `IndexStore.open()` runs eight write operations before its
/// first `SELECT`, and a 30 MB extension the system can jetsam mid-transaction must never do
/// that to the owner's irreplaceable database. So the app pre-renders; the widget opens files.
///
/// Duplicated verbatim into `KeoWidget/` rather than shared: moving the file out of the app's
/// synchronized group would mean editing the project, the check command, the README structure
/// table and the read-only scan. A source check keeps the two copies byte-identical.
struct WidgetManifest: Codable, Sendable {
    /// A widget from an older build refuses rather than decodes a shape it does not know.
    let version: Int
    let stamped: Date
    let folders: [Folder]

    struct Folder: Codable, Sendable {
        /// The Freebox path — the identity the configuration intent persists, so the choice
        /// survives a re-render that reshuffles everything else.
        let path: String
        let name: String
        /// Names of the rendered files in this folder's directory, newest capture first.
        let images: [String]
    }

    static let currentVersion = 1
    static let group = "group.com.oasutalab.keo"
    static let fileName = "widget.json"

    /// `nil` before the app has ever run, or when the group is missing from the profile. The
    /// widget renders its empty state then, rather than crashing on a Home Screen.
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    /// A NAS path is not a file name: it carries slashes, and could carry `..`. Hashing gives
    /// a flat hex name that cannot climb out of the container when the extension joins it.
    static func key(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
