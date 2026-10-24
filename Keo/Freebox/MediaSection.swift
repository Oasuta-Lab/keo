import Foundation

/// A run of media sharing a period, in the order the grid shows them.
struct MediaSection: Identifiable, Sendable, Equatable {
    /// Stable and sortable: "2024-08", "2024-08-24", or "sans-date".
    let id: String
    let title: String
    /// Position of this section's first item in the flat media array, so a cell can still
    /// compute its prefetch window without a lookup table.
    let startIndex: Int
    let items: [Item]
    /// Shown beside the rail when it differs from the previous section.
    let year: String?

    static func == (a: MediaSection, b: MediaSection) -> Bool {
        a.id == b.id && a.startIndex == b.startIndex && a.items.count == b.items.count
    }
}

enum MediaGrouping {
    static let undatedID = "sans-date"

    /// Groups by month, or by day when everything falls in a single month — a holiday folder
    /// grouped under one heading would be no better than no grouping at all.
    ///
    /// Items without a date land in a trailing section rather than being dropped: they are
    /// still browsable, just not placed in time.
    static func sections(from media: [Item],
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> [MediaSection] {
        guard !media.isEmpty else { return [] }

        let byDay = needsDayGranularity(media, calendar: calendar)
        var sections: [MediaSection] = []
        var currentKey: String?
        var current: [Item] = []
        var start = 0
        var previousYear: String?

        func flush() {
            guard let key = currentKey, !current.isEmpty else { return }
            let year = key == undatedID ? nil : String(key.prefix(4))
            sections.append(MediaSection(
                id: key,
                title: title(for: current[0], key: key, byDay: byDay, calendar: calendar, locale: locale),
                startIndex: start,
                items: current,
                year: year == previousYear ? nil : year
            ))
            previousYear = year ?? previousYear
            start += current.count
            current = []
        }

        for item in media {
            let key = self.key(for: item, byDay: byDay, calendar: calendar)
            if key != currentKey {
                flush()
                currentKey = key
            }
            current.append(item)
        }
        flush()
        return sections
    }

    private static func needsDayGranularity(_ media: [Item], calendar: Calendar) -> Bool {
        var months = Set<String>()
        for item in media where item.modified != nil {
            months.insert(key(for: item, byDay: false, calendar: calendar))
            if months.count > 1 { return false }
        }
        return months.count == 1 && media.count > 20
    }

    private static func key(for item: Item, byDay: Bool, calendar: Calendar) -> String {
        guard let date = item.modified else { return undatedID }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        guard byDay else { return String(format: "%04d-%02d", year, month) }
        return String(format: "%04d-%02d-%02d", year, month, parts.day ?? 0)
    }

    private static func title(for item: Item, key: String, byDay: Bool,
                              calendar: Calendar, locale: Locale) -> String {
        guard let date = item.modified else { return "Sans date" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(byDay ? "dMMMMyyyy" : "MMMMyyyy")
        let text = formatter.string(from: date)
        return String(text.prefix(1)).uppercased(with: locale) + text.dropFirst()
    }
}
