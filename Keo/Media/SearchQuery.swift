import Foundation

/// What the user is looking for. Pure, so the matching rules can be checked without a database.
struct SearchQuery: Equatable, Hashable, Sendable {
    enum Kinds: String, CaseIterable, Sendable {
        case everything, photos, videos, documents

        var label: String {
            switch self {
            case .everything: return "Tout"
            case .photos: return "Photos"
            case .videos: return "Vidéos"
            case .documents: return "Fichiers"
            }
        }

        /// Matches `Item.Kind.code`. Folders never appear here: they have no type.
        var codes: [Int] {
            switch self {
            case .everything: return [1, 2, 3]
            case .photos: return [1]
            case .videos: return [2]
            case .documents: return [3]
            }
        }
    }

    /// When the photos were taken. A single value, not a year *and* a range: two controls
    /// that both narrow the same axis is how they end up contradicting each other.
    enum Period: Hashable, Sendable {
        case any
        case year(Int)
        case between(Date, Date)

        var isSet: Bool {
            if case .any = self { return false }
            return true
        }

        /// The seconds a capture date must fall in, or `nil` for no restriction.
        /// Both ends are inclusive and whole days, so picking the same date twice still
        /// matches that day rather than nothing.
        func range(_ calendar: Calendar = .current) -> ClosedRange<Double>? {
            switch self {
            case .any:
                return nil
            case .year(let year):
                guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                      let end = calendar.date(byAdding: .year, value: 1, to: start)
                else { return nil }
                return start.timeIntervalSince1970...(end.timeIntervalSince1970 - 1)
            case .between(let from, let to):
                let (low, high) = from <= to ? (from, to) : (to, from)
                let start = calendar.startOfDay(for: low)
                guard let end = calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: high))
                else { return nil }
                return start.timeIntervalSince1970...(end.timeIntervalSince1970 - 1)
            }
        }
    }

    var text = ""
    var kinds: Kinds = .everything
    var favouritesOnly = false
    var period: Period = .any

    /// Nothing typed and nothing filtered: show the prompt rather than the whole NAS.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && kinds == .everything && !favouritesOnly && !period.isSet
    }

    /// Case- and accent-insensitive. French folders are called `Été` and `Vidéos`; a search
    /// that only matches the exact spelling is useless here.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "fr_FR"))
    }

    /// `%` and `_` are wildcards in SQL; a filename may legitimately contain either.
    static func pattern(for text: String) -> String {
        let escaped = fold(text.trimmingCharacters(in: .whitespaces))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
