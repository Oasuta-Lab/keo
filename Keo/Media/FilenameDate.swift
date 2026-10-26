import Foundation

/// A date recovered from the file's *name* — `IMG_20190714_103000.jpg`,
/// `Screenshot_2021-03-02-10-20-30.png`, WhatsApp's `IMG-20210302-WA0001.jpg`.
///
/// This is a different kind of truth from a capture date: the name says what some device or
/// app chose to call the file, not when a shutter fired. It must never be stored or shown as
/// a capture date — « sans date » is a statement about the file's metadata, and a date of this
/// kind does not change it. Nothing in the app consumes it yet: the measurement it was built
/// for has been taken (README, « 6,9 % sans date »), and what it would unlock is a *labelled*
/// fallback on the timeline — a product decision nobody has made. It stays parked, with its
/// checks, rather than being wired in by default.
enum FilenameDate {
    /// First plausible yyyyMMdd (optionally separated, the separator repeating) in the name,
    /// with an optional hhmmss behind it. Lookarounds keep a longer digit run — a serial, a
    /// phone number — from donating eight of its digits.
    private static let pattern: NSRegularExpression = {
        let date = #"(?<!\d)((?:19|20)\d{2})([-._]?)(0[1-9]|1[0-2])\2(0[1-9]|[12]\d|3[01])"#
        // " à " and " at " are macOS screenshot names; the rest covers phones and apps.
        let time = #"(?:(?:[-._ T]| à | at )?([01]\d|2[0-3])[-.:h_]?([0-5]\d)[-.:m_]?([0-5]\d))?(?!\d)"#
        return try! NSRegularExpression(pattern: date + time)
    }()

    static func capture(from name: String, now: Date = Date()) -> Date? {
        let whole = NSRange(name.startIndex..., in: name)
        guard let match = pattern.firstMatch(in: name, range: whole) else { return nil }

        func group(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let bounds = Range(range, in: name) else {
                return nil
            }
            return Int(name[bounds])
        }
        guard let year = group(1), let month = group(3), let day = group(4) else { return nil }

        var parts = DateComponents(year: year, month: month, day: day)
        // Noon when the name carries no time: a date must not slip to the previous or next
        // day the moment the device changes timezone.
        parts.hour = group(5) ?? 12
        parts.minute = group(6) ?? 0
        parts.second = group(7) ?? 0

        // Local time, like an EXIF stamp: a filename knows no timezone either.
        let calendar = Calendar.current
        guard parts.isValidDate(in: calendar), let date = calendar.date(from: parts) else {
            return nil
        }
        // Same plausibility window as the video parser: below 1990 is tool garbage, beyond
        // two days from now is a name that lies — worse on the timeline than no date.
        guard date.timeIntervalSince1970 >= 631_152_000,
              date <= now.addingTimeInterval(172_800) else { return nil }
        return date
    }
}
