import Foundation

/// Dates the way a person says them, for the surfaces where a date is a memory rather than a
/// fact: "Il y a sept ans", "Un mardi de juillet 2019".
///
/// Deliberately not used in the viewer's caption, nor anywhere the date is evidence — there
/// the exact date is the information, and `MediaDate`'s hard-won "Modifié le" honesty stands.
/// Pure and outside SwiftUI so the arithmetic that is easy to get wrong at year boundaries can
/// be pinned down.
enum HumanDate {
    /// Spelled out up to twelve, then numerals — the French typographic rule, and the point at
    /// which a word stops reading faster than a figure.
    private static let spelled = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six",
                                  "sept", "huit", "neuf", "dix", "onze", "douze"]

    /// "Il y a sept ans", "L'année dernière", "Cette année".
    static func yearsAgo(from then: Date, to now: Date = Date(),
                         calendar: Calendar = .current) -> String {
        let years = calendar.component(.year, from: now) - calendar.component(.year, from: then)
        switch years {
        case ..<1: return "Cette année"
        case 1: return "L'année dernière"
        default:
            let count = years < spelled.count ? spelled[years] : String(years)
            return "Il y a \(count) ans"
        }
    }

    /// "Un mardi de juillet 2019" — the weekday carries more of a memory than the day number,
    /// which nobody remembers anyway.
    static func story(_ day: Date, locale: Locale = .current,
                      calendar: Calendar = .current) -> String {
        let weekday = formatter("EEEE", locale).string(from: day).lowercased(with: locale)
        let month = formatter("LLLL", locale).string(from: day).lowercased(with: locale)
        let year = calendar.component(.year, from: day)
        // "Un" and not "Le": there were four Tuesdays that July and this is one of them.
        return "Un \(weekday) de \(month) \(year)"
    }

    /// "Juillet 2009 — il y a dix-sept ans".
    static func origin(_ day: Date, now: Date = Date(), locale: Locale = .current,
                       calendar: Calendar = .current) -> String {
        let month = formatter("LLLL yyyy", locale).string(from: day)
        let since = yearsAgo(from: day, to: now, calendar: calendar).lowercased(with: locale)
        return month.prefix(1).uppercased() + month.dropFirst() + " — " + since
    }

    private static func formatter(_ template: String, _ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
