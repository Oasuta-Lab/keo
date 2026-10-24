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

/// How finely the grid is cut in time. Zooming out turns fifteen years of months into
/// fifteen headings instead of a hundred and eighty.
enum Granularity: String, CaseIterable, Sendable {
    case year, month, day

    var label: String {
        switch self {
        case .year: return "Années"
        case .month: return "Mois"
        case .day: return "Jours"
        }
    }

    var systemImage: String {
        switch self {
        case .year: return "square.grid.4x3.fill"
        case .month: return "square.grid.3x3.fill"
        case .day: return "square.grid.2x2.fill"
        }
    }

    /// Smaller cells when zoomed out: the point is to see the shape of a year at a glance.
    var cellWidth: CGFloat {
        switch self {
        case .year: return 72
        case .month: return 110
        case .day: return 164
        }
    }

    var coarser: Granularity? {
        switch self {
        case .day: return .month
        case .month: return .year
        case .year: return nil
        }
    }

    var finer: Granularity? {
        switch self {
        case .year: return .month
        case .month: return .day
        case .day: return nil
        }
    }

    fileprivate var template: String {
        switch self {
        case .year: return "yyyy"
        case .month: return "MMMMyyyy"
        case .day: return "dMMMMyyyy"
        }
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
                         granularity: Granularity = .month,
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> [MediaSection] {
        guard !media.isEmpty else { return [] }

        // One `dateComponents` per item, reused for both granularities. Asking twice cost
        // 40 000 calls on a 20 000 photo folder.
        var stamps: [Stamp] = []
        stamps.reserveCapacity(media.count)
        var months = Set<Int>()
        for item in media {
            let stamp = Stamp(item.timelineDate, calendar: calendar)
            if let month = stamp.month { months.insert(month) }
            stamps.append(stamp)
        }

        // A folder that fits in one month gets cut by day on its own: a single heading would
        // group nothing at all.
        var cut = granularity
        if cut == .month, months.count == 1, media.count > 20 { cut = .day }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(cut.template)

        var sections: [MediaSection] = []
        var currentKey: String?
        var current: [Item] = []
        var start = 0
        var previousYear: String?

        func flush(_ stamp: Stamp?) {
            guard let key = currentKey, !current.isEmpty else { return }
            let year = key == undatedID ? nil : String(key.prefix(4))
            sections.append(MediaSection(
                id: key,
                title: stamp?.date.map { title($0, formatter: formatter, locale: locale) }
                    ?? "Sans date",
                startIndex: start,
                items: current,
                year: year == previousYear ? nil : year
            ))
            previousYear = year ?? previousYear
            start += current.count
            current = []
        }

        // Bucket comparison is on integers: building 20 000 formatted strings just to detect
        // boundaries was most of the cost of this pass.
        var pending: Stamp?
        var currentBucket: Int?
        for (item, stamp) in zip(media, stamps) {
            let bucket = stamp.bucket(cut)
            if bucket != currentBucket {
                flush(pending)
                currentBucket = bucket
                currentKey = stamp.key(cut)
                pending = stamp
            }
            current.append(item)
        }
        flush(pending)
        return sections
    }

    /// Year, month and day pulled out once, plus the date itself for the heading.
    private struct Stamp {
        let date: Date?
        private let year: Int
        private let monthOfYear: Int
        private let day: Int

        init(_ date: Date?, calendar: Calendar) {
            self.date = date
            guard let date else {
                year = 0; monthOfYear = 0; day = 0
                return
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            year = parts.year ?? 0
            monthOfYear = parts.month ?? 0
            day = parts.day ?? 0
        }

        /// Distinct value per calendar month, for deciding the granularity.
        var month: Int? { date == nil ? nil : year * 12 + monthOfYear }

        /// Cheap boundary test; the printable key is only built once per section.
        func bucket(_ cut: Granularity) -> Int {
            guard date != nil else { return -1 }
            switch cut {
            case .year: return year
            case .month: return year * 100 + monthOfYear
            case .day: return year * 10_000 + monthOfYear * 100 + day
            }
        }

        func key(_ cut: Granularity) -> String {
            guard date != nil else { return MediaGrouping.undatedID }
            switch cut {
            case .year: return String(format: "%04d", year)
            case .month: return String(format: "%04d-%02d", year, monthOfYear)
            case .day: return String(format: "%04d-%02d-%02d", year, monthOfYear, day)
            }
        }
    }

    private static func title(_ date: Date, formatter: DateFormatter, locale: Locale) -> String {
        let text = formatter.string(from: date)
        return String(text.prefix(1)).uppercased(with: locale) + text.dropFirst()
    }
}
