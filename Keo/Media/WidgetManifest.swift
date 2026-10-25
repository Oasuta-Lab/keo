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
    /// Absent when nothing was taken on this day in any past year — which is most days of a
    /// small library, and a widget that says so beats one that shows yesterday's photo again.
    let onThisDay: Memory?

    struct Folder: Codable, Sendable {
        /// The Freebox path — the identity the configuration intent persists, so the choice
        /// survives a re-render that reshuffles everything else.
        let path: String
        let name: String
        /// Names of the rendered files in this folder's directory, newest capture first.
        let images: [String]
        /// Photos and videos in the whole subtree. `nil` while the folder is not fully
        /// indexed: a count that silently under-reports is worse than no count.
        let mediaCount: Int?
        /// `"2009 – 2024"`, or `nil` when no file in it has a capture date.
        let span: String?
    }

    /// Photos taken on today's month and day, in years gone by.
    struct Memory: Codable, Sendable {
        /// Rendered file names, newest first, in `Library/Widget/<dayKey>/`.
        let images: [String]
        /// The year each image was taken, in the same order — so the widget can say
        /// "il y a 7 ans" without parsing anything.
        let years: [Int]
        /// `"25 octobre"`, already localised by the app: the extension has no business
        /// formatting a date the app already knows how to write.
        let label: String
        /// Total found for the day, which can exceed what was rendered.
        let total: Int
    }

    static let currentVersion = 2
    static let group = "group.com.oasutalab.keo"
    static let fileName = "widget.json"
    /// Fixed name for the memories directory, so a stale day's files are overwritten rather
    /// than accumulating one directory per day of the year.
    static let dayKey = "jour"

    /// `nil` before the app has ever run, or when the group is missing from the profile. The
    /// widget renders its empty state then, rather than crashing on a Home Screen.
    ///
    /// Under `Library/` on purpose: `devicectl device copy from` only reaches `Library`,
    /// `Documents` and `tmp`, and a widget that cannot be inspected from the Mac is a widget
    /// debugged by guesswork.
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Widget", isDirectory: true)
    }

    /// A NAS path is not a file name: it carries slashes, and could carry `..`. Hashing gives
    /// a flat hex name that cannot climb out of the container when the extension joins it.
    static func key(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where a tap lands. The app registers `keo://` and opens the folder; without this the
    /// widget is decoration, since tapping it drops you at the root of the NAS.
    static func link(folder path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "keo"
        parts.host = "folder"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url
    }

    /// The memories widget opens the search screen on that day rather than a folder: the
    /// photos it shows come from everywhere at once.
    static func link(day: Date) -> URL? {
        var parts = URLComponents()
        parts.scheme = "keo"
        parts.host = "day"
        parts.queryItems = [URLQueryItem(name: "stamp",
                                         value: String(Int(day.timeIntervalSince1970)))]
        return parts.url
    }
}
