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
    /// Not a photo, and written on passes where no photo is: see `Coverage`.
    let coverage: Coverage

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

    /// How much of the library the index has actually read.
    ///
    /// Five integers rather than a sentence, because the sentence belongs to the widget and
    /// the arithmetic has to be checkable. Written on every foreground pass, including the
    /// ones where no photo is rendered: the index only ever moves while the app is open, so
    /// the pass that follows a session is the single chance to record where it got to.
    struct Coverage: Codable, Sendable, Equatable {
        /// Folders the index has heard of, and those it has read end to end. The first grows
        /// as the walk discovers new ones, so `fraction` can go *down* between two glances.
        /// That is the truth — a folder nobody has listed exists nowhere and can be counted
        /// by nothing — and the statistics screen says the same thing in words.
        var knownFolders = 0
        var indexedFolders = 0
        /// Listed but never opened — a truth about the index. They may well carry a date.
        var unreadFiles = 0
        /// Read end to end and still carrying no capture date — a truth about the files.
        /// Never added to the one above: different population, different fix, and summing
        /// them would describe neither. The two are shown one at a time, never together.
        var datelessFiles = 0
        var fileCount = 0

        /// Nothing read yet, which is a different sentence from "nothing left to read".
        var isEmpty: Bool { fileCount == 0 }
        /// The same test as `HomeSummary.isPartial`, so the Lock Screen and the Bibliothèque
        /// card can never disagree about whether the library is done.
        var isPartial: Bool { indexedFolders < knownFolders || unreadFiles > 0 }

        /// As complete as its least complete half. A bar filling up on folders while files
        /// are still unread would promise a finish that has not happened; the other way
        /// round, a bar full of read files says nothing about folders never listed.
        var fraction: Double {
            guard !isEmpty else { return 0 }
            let walked = knownFolders > 0 ? Double(indexedFolders) / Double(knownFolders) : 1
            let read = Double(fileCount - unreadFiles) / Double(fileCount)
            return max(0, min(walked, read, 1))
        }

        /// Rounded **down**, never to nearest: 99.6 % printed as « 100 % » while files are
        /// still unread is the one number this widget exists not to print.
        var percent: Int { Int((fraction * 100).rounded(.down)) }

        /// The three states the index can be in, in the words the Bibliothèque card already
        /// uses. Here rather than in the view so the check command can hold them: the order
        /// of these branches *is* the honesty rule.
        ///
        /// « pas encore lus » and « sans date » never appear together and are never added
        /// up — the first is a truth about the index, the second a truth about the files,
        /// and the walk has to be finished before the second one is even knowable.
        ///
        /// The total file count is deliberately absent from the finished state: on its own
        /// it flatters without teaching anything, which is why the statistics screen keeps
        /// it only as the denominator of its banner. The residue of undated files is the one
        /// thing a complete index still has to say.
        var lines: (headline: String, detail: String?) {
            if isEmpty { return ("Index vide", "Ouvre Keo pour le construire") }
            if indexedFolders < knownFolders {
                return ("\(indexedFolders.formatted()) dossiers sur \(knownFolders.formatted())",
                        unreadFiles > 0
                            ? "\(unreadFiles.formatted()) fichiers pas encore lus" : nil)
            }
            if unreadFiles > 0 {
                return ("\(unreadFiles.formatted()) fichiers pas encore lus",
                        "Tous les dossiers sont parcourus")
            }
            return ("Bibliothèque à jour",
                    datelessFiles > 0 ? "\(datelessFiles.formatted()) fichiers sans date" : nil)
        }
    }

    static let currentVersion = 3
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

    /// The coverage widget's single destination — the statistics screen, not the indexing
    /// one. A widget has room for a number but never for the reserve that makes it honest:
    /// « sans date » against « pas encore lues », « même nom, même taille » against a real
    /// fingerprint. So its tap lands where those reserves are printed, which is also where
    /// the button that resumes the walk sits.
    static var statistics: URL? {
        var parts = URLComponents()
        parts.scheme = "keo"
        parts.host = "stats"
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
