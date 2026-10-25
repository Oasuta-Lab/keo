import Foundation

/// What the user is looking for. Pure, so the matching rules can be checked without a database.
struct SearchQuery: Equatable, Hashable, Sendable {
    enum Kinds: String, CaseIterable, Sendable {
        case everything, photos, videos

        var label: String {
            switch self {
            case .everything: return "Tout"
            case .photos: return "Photos"
            case .videos: return "Vidéos"
            }
        }
    }

    var text = ""
    var kinds: Kinds = .everything
    var favouritesOnly = false
    /// `nil` means every year.
    var year: Int?

    /// Nothing typed and nothing filtered: show the prompt rather than the whole NAS.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && kinds == .everything && !favouritesOnly && year == nil
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
