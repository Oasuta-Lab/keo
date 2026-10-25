import Foundation

/// Everything the statistics screen shows, read in one pass over the index.
///
/// The screen is honest or it is worthless: half of what follows exists only to say how much
/// of the library the other half was computed on. Nothing here is ever derived from the NAS —
/// only from what the index has actually seen.
struct LibraryStats: Sendable {
    /// Folders the index knows of, and those it has read end to end. The second is the only
    /// population every number below is computed on.
    var knownFolders = 0
    var indexedFolders = 0
    /// Files seen in a listing but never opened: a size, a name, and no date.
    var unreadFiles = 0

    var years: [YearTally] = []
    /// Media read end to end that genuinely carry no date — a truth about the files.
    var datelessRead = 0
    /// Media not read yet. They may well be dated; nobody has looked — a truth about the index.
    var datelessUnread = 0
    var firstCapture: Date?
    var gap: Gap?

    var kinds: [KindTally] = []
    var subtrees: [Subtree] = []

    var duplicates = DuplicateTotals()
    var worstDuplicates: [DuplicateGroup] = []

    var biggest: [Item] = []
    var busiestDays: [DayTally] = []
    var onThisDay: [Item] = []

    /// Whether the banner has to appear. A fully walked index needs no excuse.
    var isPartial: Bool { indexedFolders < knownFolders || unreadFiles > 0 }

    var coverage: String {
        "Statistiques calculées sur les \(indexedFolders.formatted()) dossiers indexés "
            + "(sur \(knownFolders.formatted()) connus) · "
            + "\(unreadFiles.formatted()) fichiers jamais lus"
    }
}

/// What the home screen needs, and nothing else.
///
/// `LibraryStats` costs a dozen scans of the index — fine once, on a screen someone chose to
/// open. The home screen opens every time the app does, so it asks five questions instead.
struct HomeSummary: Sendable {
    /// Taken on this day, in years gone by.
    var memories: [Item] = []
    var years: [YearTally] = []
    var firstCapture: Date?
    var knownFolders = 0
    var indexedFolders = 0
    var unreadFiles = 0
    var fileCount = 0
    /// Weight of everything the index has weighed. Not the disk's capacity — that lives on
    /// the box, and this screen must mean something with the box switched off.
    var bytes: Int64 = 0
    /// Folders stamped without a weight: the total is a floor, not a figure.
    var unweighed = 0

    var isEmpty: Bool { fileCount == 0 }
    /// Something is known, but not everything — the card says so rather than rounding up.
    var isPartial: Bool { indexedFolders < knownFolders || unreadFiles > 0 }
}

struct YearTally: Sendable, Identifiable {
    let year: Int
    let photos: Int
    let videos: Int

    var id: Int { year }
    var total: Int { photos + videos }
}

struct KindTally: Sendable {
    let kind: Item.Kind
    let count: Int
    let bytes: Int64
}

struct DayTally: Sendable, Identifiable {
    let day: Date
    let count: Int

    var id: Date { day }
}

/// One heaviest-subtree row: a direct child of the browsed folder, summed over everything
/// beneath it.
struct Subtree: Sendable, Identifiable {
    let name: String
    let path: String
    let bytes: Int64
    let media: Int
    let folders: Int
    /// Folders in there the pass never finished. Their weight is not zero, it is unknown.
    let unweighed: Int

    var id: String { path }

    /// A subtree holding unweighed folders can only promise a floor: printing a flat total
    /// would quietly under-report by however much those folders turn out to hold.
    var weight: String {
        let total = bytes.formatted(.byteCount(style: .file))
        guard unweighed > 0 else { return total }
        let plural = unweighed > 1 ? "s" : ""
        return "≥ \(total) · \(unweighed) dossier\(plural) pas encore pesé\(plural)"
    }

    /// Width of the bar, relative to the heaviest row. Zero bytes draws nothing rather than a
    /// sliver: a subtree that has only been listed has not been measured at all.
    func fraction(of heaviest: Int64) -> Double {
        guard heaviest > 0, bytes > 0 else { return 0 }
        return max(Double(bytes) / Double(heaviest), 0.015)
    }
}

struct DuplicateTotals: Sendable {
    var groups = 0
    var extraFiles = 0
    var recoverableBytes: Int64 = 0
}

struct DuplicateGroup: Sendable, Identifiable {
    let name: String
    let size: Int64
    let copies: Int

    var id: String { "\(size)/\(name)" }
    var detail: String {
        "\(copies) exemplaires · \(size.formatted(.byteCount(style: .file))) chacun"
    }
}

/// A stretch of months with no photo at all, between two months that do hold some.
struct Gap: Equatable, Sendable {
    let silentMonths: Int
    /// Months encoded as `year * 12 + (month - 1)`, which SQLite computes directly.
    let from: Int
    let to: Int

    var label: String {
        "\(silentMonths) mois sans photo, \(Statistics.monthName(from)) – \(Statistics.monthName(to))"
    }
}

/// The maths behind the screen, kept out of SwiftUI so it can be checked.
enum Statistics {
    /// The prefix every path inside a subtree starts with.
    ///
    /// Spelled as a prefix rather than as `path || '/'` because the root is `/`: appending a
    /// slash there yields `//`, which matches nothing at all. Checked in `Tests/stats.swift`.
    static func scopePrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// The longest silence between two months that hold photos. Ties keep the earliest, so
    /// the sentence does not move around between two runs on the same index.
    static func longestGap(_ months: [Int]) -> Gap? {
        let sorted = months.sorted()
        var longest: Gap?
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            let silent = later - earlier - 1
            guard silent > 0, silent > (longest?.silentMonths ?? 0) else { continue }
            longest = Gap(silentMonths: silent, from: earlier, to: later)
        }
        return longest
    }

    /// The type split as one sentence. A pie chart of three slices says strictly less.
    static func kindSentence(_ tallies: [KindTally]) -> String? {
        guard !tallies.isEmpty else { return nil }
        let labels: [Item.Kind: (String, String)] = [
            .image: ("photo", "photos"),
            .video: ("vidéo", "vidéos"),
            .other: ("autre fichier", "autres fichiers"),
        ]
        let parts = tallies.compactMap { tally -> String? in
            guard let (one, many) = labels[tally.kind], tally.count > 0 else { return nil }
            return "\(tally.count.formatted()) \(tally.count > 1 ? many : one)"
        }
        guard !parts.isEmpty else { return nil }
        let bytes = tallies.reduce(Int64(0)) { $0 + $1.bytes }
        return parts.joined(separator: ", ")
            + ", \(bytes.formatted(.byteCount(style: .file))) en tout"
    }

    /// `YYYY-MM-DD` as SQLite spells it, read back in the device's own time zone — the same
    /// one `strftime(…, 'localtime')` grouped by, and the one a day filter will use.
    static func day(_ text: String) -> Date? { dayFormatter.date(from: text) }

    /// `MM-DD`, the shape `strftime('%m-%d', …)` produces for "the same day, other years".
    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }

    static func monthName(_ encoded: Int) -> String {
        let components = DateComponents(year: encoded / 12, month: encoded % 12 + 1, day: 1)
        guard let date = Calendar.current.date(from: components) else { return "?" }
        return monthFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        return formatter
    }()
}
