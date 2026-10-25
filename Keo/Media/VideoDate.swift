import Foundation

/// Capture date of an ISO-BMFF / QuickTime video (.mov, .mp4, .m4v, .3gp), read from byte
/// windows fetched over HTTP Range — the file is never downloaded.
///
/// The scanner is a pure function over the windows fetched so far. Its verdict is
/// deliberately three-valued, because the one mistake that must never happen is recording
/// "this file has no date" when the truth is "the bytes that would tell us were not fetched":
///
/// - `.found(Date)`   — a capture date was read;
/// - `.absent`        — the relevant atoms were seen and carry no usable date. Safe to record.
/// - `.need(range)`   — nothing can be concluded without these bytes. The caller must fetch
///                      that range (as ONE contiguous window) and scan again — never record.
///
/// Date preference, best first:
/// 1. `moov/meta` key `com.apple.quicktime.creationdate` — ISO-8601 with timezone, written at
///    capture by iPhones. Survives copies; the only value that knows the local time.
/// 2. `©day`, in `moov/udta/meta/ilst` (iTunes style) or directly in `moov/udta` (classic
///    QuickTime) — same intent, written by cameras and tagging software.
/// 3. `mvhd` creation_time (seconds since 1904-01-01 UTC) — every file has one, but a
///    re-encode or a copy tool may have reset it; last resort, filtered for plausibility.
///
/// Implausible values (0, 1904, the epoch, far future) are rejected rather than returned:
/// a wrong date is worse than none, it silently corrupts the timeline.
enum VideoDate {

    /// A window of the file: `data` holds bytes [offset, offset + data.count).
    struct Slice: Sendable {
        let offset: Int64
        let data: Data
    }

    enum Scan: Equatable, Sendable {
        case found(Date)
        case absent
        case need(Range<Int64>)
    }

    /// Thrown when the request budget runs out or the server shorts a range: the caller must
    /// treat it like a network failure — retry later, never record "no date".
    struct Undecided: Error {}

    // MARK: - Driver

    /// Floor on every range request; a short clip's whole `moov` usually fits in one.
    static let chunk: Int64 = 64 << 10
    /// When the whole `moov` is at most this big, it is fetched in one request instead of
    /// hopping child by child. Covers virtually every phone clip.
    static let moovSlurp: Int64 = 512 << 10
    /// A legitimate file resolves in 2–5 requests; past this something is wrong.
    static let maxRequests = 8

    /// Fetches just enough of the file to decide. Returns the capture date, `nil` for the
    /// sure verdict "this file carries none", and throws `Undecided` (or the fetch's own
    /// error) when no conclusion is possible yet — so the entry stays retryable.
    static func capture(fileSize: Int64, now: Date = Date(),
                        fetch: (Range<Int64>) async throws -> Data) async throws -> Date? {
        guard fileSize >= 16 else { return nil }
        var slices: [Slice] = []
        for _ in 0..<maxRequests {
            switch scan(slices, fileSize: fileSize, now: now) {
            case .found(let date):
                return date
            case .absent:
                return nil
            case .need(let range):
                let lower = max(0, range.lowerBound)
                let upper = min(fileSize, max(range.upperBound, lower + chunk))
                guard lower < upper else { throw Undecided() }
                let data = try await fetch(lower ..< upper)
                // The window must cover what was asked, or the next scan cannot progress.
                guard Int64(data.count) >= range.upperBound - lower else { throw Undecided() }
                slices.append(Slice(offset: lower, data: data))
            }
        }
        throw Undecided()
    }

    // MARK: - Pure scanner

    /// Walks the top-level atoms looking for `moov`. Pure: same slices, same verdict.
    /// A `.need` must be satisfied by one contiguous slice covering the returned range.
    static func scan(_ slices: [Slice], fileSize: Int64, now: Date = Date()) -> Scan {
        let r = Reader(slices: slices, fileSize: fileSize)
        var cursor: Int64 = 0
        var hops = 0
        while cursor + 8 <= fileSize {
            hops += 1
            guard hops <= 1_000 else { return .absent }
            switch piece(r, at: cursor, end: fileSize) {
            case .need(let range):
                return .need(range)
            case .corrupt:
                return .absent
            case .box(let type, let body, let end):
                // Reject non-ISO-BMFF upfront (AVI, MKV, TS…): their first bytes never
                // spell a plausible leading atom, and no amount of fetching will help.
                if cursor == 0, !plausibleFirst.contains(type) { return .absent }
                if type == Fourcc.moov { return scanMoov(r, body: body, end: end, now: now) }
                cursor = end
            }
        }
        return .absent // no moov anywhere: nothing to date, sure verdict
    }

    private static func scanMoov(_ r: Reader, body: Int64, end: Int64, now: Date) -> Scan {
        // Small moov (every phone clip): claim the whole thing in one request.
        if end > body, end - body <= moovSlurp, r.bytes(at: body, count: Int(end - body)) == nil {
            return .need(body ..< end)
        }
        let kids: [Child]
        switch walk(r, from: body, to: end) {
        case .need(let range): return .need(range)
        case .kids(let found): kids = found
        }
        // Best first; a `.need` from a better source must win over a worse date in hand.
        if let meta = kids.first(Fourcc.meta) {
            let verdict = metaCreationDate(r, meta, now: now)
            if verdict != .absent { return verdict }
        }
        if let udta = kids.first(Fourcc.udta) {
            let verdict = udtaDay(r, udta, now: now)
            if verdict != .absent { return verdict }
        }
        if let mvhd = kids.first(Fourcc.mvhd) {
            return mvhdDate(r, mvhd, now: now)
        }
        return .absent
    }

    /// `moov/meta` with `mdta` keys: the `com.apple.quicktime.creationdate` path.
    private static func metaCreationDate(_ r: Reader, _ meta: Range<Int64>, now: Date) -> Scan {
        let start: Int64
        switch metaChildrenStart(r, meta) {
        case .bail(let scan): return scan
        case .at(let at): start = at
        }
        let kids: [Child]
        switch walk(r, from: start, to: meta.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): kids = found
        }
        guard let keys = kids.first(Fourcc.keys), let ilst = kids.first(Fourcc.ilst) else {
            return .absent
        }
        // keys: version/flags, entry_count, then (size, 'mdta', name) entries, 1-indexed.
        guard let rawCount = r.u32(at: keys.lowerBound + 4) else {
            return .need(keys.lowerBound ..< min(keys.lowerBound + 8, keys.upperBound))
        }
        guard rawCount <= 4_096 else { return .absent }
        var index: UInt32?
        var p = keys.lowerBound + 8
        for i in 1...max(rawCount, 1) where rawCount > 0 {
            guard p + 8 <= keys.upperBound else { break }
            guard let entrySize = r.u32(at: p) else { return .need(p ..< keys.upperBound) }
            guard entrySize >= 8, Int64(entrySize) <= keys.upperBound - p else { break }
            if entrySize > 8 {
                guard let name = r.bytes(at: p + 8, count: Int(entrySize) - 8) else {
                    return .need(p ..< keys.upperBound)
                }
                if String(decoding: name, as: UTF8.self) == "com.apple.quicktime.creationdate" {
                    index = UInt32(i)
                    break
                }
            }
            p += Int64(entrySize)
        }
        guard let index else { return .absent }
        // ilst children are typed by that 1-based index rather than by a four-cc.
        return ilstString(r, ilst, childType: index, now: now)
    }

    /// `©day`, either straight in `udta` (classic QuickTime) or via `udta/meta/ilst` (iTunes).
    private static func udtaDay(_ r: Reader, _ udta: Range<Int64>, now: Date) -> Scan {
        let kids: [Child]
        switch walk(r, from: udta.lowerBound, to: udta.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): kids = found
        }
        if let day = kids.first(Fourcc.day) {
            // Body is a list of (u16 size, u16 language, text); the first entry is enough.
            if day.upperBound - day.lowerBound >= 4, let head = r.bytes(at: day.lowerBound, count: 4) {
                let bytes = [UInt8](head)
                let size = Int(bytes[0]) << 8 | Int(bytes[1])
                if size > 0, Int64(4 + size) <= day.upperBound - day.lowerBound,
                   let text = r.bytes(at: day.lowerBound + 4, count: size),
                   let date = parse(String(decoding: text, as: UTF8.self), now: now) {
                    return .found(date)
                }
            } else if day.upperBound > day.lowerBound {
                return .need(day.lowerBound ..< day.upperBound)
            }
        }
        if let meta = kids.first(Fourcc.meta) {
            let start: Int64
            switch metaChildrenStart(r, meta) {
            case .bail(let scan): return scan
            case .at(let at): start = at
            }
            switch walk(r, from: start, to: meta.upperBound) {
            case .need(let range): return .need(range)
            case .kids(let inner):
                if let ilst = inner.first(Fourcc.ilst) {
                    return ilstString(r, ilst, childType: Fourcc.day, now: now)
                }
            }
        }
        return .absent
    }

    /// Finds `childType` in an `ilst`, reads its `data` atom's string payload, parses it.
    private static func ilstString(_ r: Reader, _ ilst: Range<Int64>,
                                   childType: UInt32, now: Date) -> Scan {
        let entries: [Child]
        switch walk(r, from: ilst.lowerBound, to: ilst.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): entries = found
        }
        guard let entry = entries.first(childType) else { return .absent }
        let inner: [Child]
        switch walk(r, from: entry.lowerBound, to: entry.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): inner = found
        }
        guard let data = inner.first(Fourcc.data),
              data.upperBound - data.lowerBound > 8 else { return .absent }
        // data atom body: 4 bytes type indicator, 4 bytes locale, then the value.
        guard let text = r.bytes(at: data.lowerBound + 8,
                                 count: Int(data.upperBound - data.lowerBound - 8)) else {
            return .need(data.lowerBound ..< data.upperBound)
        }
        guard let date = parse(String(decoding: text, as: UTF8.self), now: now) else {
            return .absent
        }
        return .found(date)
    }

    /// `mvhd` creation_time: seconds since 1904-01-01 UTC, 32 or 64 bits depending on version.
    private static func mvhdDate(_ r: Reader, _ mvhd: Range<Int64>, now: Date) -> Scan {
        guard let versionFlags = r.u32(at: mvhd.lowerBound) else {
            return .need(mvhd.lowerBound ..< min(mvhd.lowerBound + 16, mvhd.upperBound))
        }
        let raw: UInt64?
        if versionFlags >> 24 == 1 {
            raw = r.u64(at: mvhd.lowerBound + 4)
        } else {
            raw = r.u32(at: mvhd.lowerBound + 4).map(UInt64.init)
        }
        guard let raw else {
            return .need(mvhd.lowerBound ..< min(mvhd.lowerBound + 16, mvhd.upperBound))
        }
        guard raw != 0 else { return .absent }
        let asMac = Date(timeIntervalSince1970: Double(raw) - 2_082_844_800)
        if plausible(asMac, now: now) { return .found(asMac) }
        // Known writer bug: some encoders store Unix time in a 1904-epoch field. Read as
        // 1904 it lands in the late 1950s; read as Unix it lands on the real day.
        let asUnix = Date(timeIntervalSince1970: Double(raw))
        if plausible(asUnix, now: now) { return .found(asUnix) }
        return .absent
    }

    // MARK: - Atom plumbing

    enum Fourcc {
        static let ftyp: UInt32 = 0x6674_7970
        static let styp: UInt32 = 0x7374_7970
        static let moov: UInt32 = 0x6D6F_6F76
        static let mdat: UInt32 = 0x6D64_6174
        static let free: UInt32 = 0x6672_6565
        static let skip: UInt32 = 0x736B_6970
        static let wide: UInt32 = 0x7769_6465
        static let pnot: UInt32 = 0x706E_6F74
        static let uuid: UInt32 = 0x7575_6964
        static let mvhd: UInt32 = 0x6D76_6864
        static let udta: UInt32 = 0x7564_7461
        static let meta: UInt32 = 0x6D65_7461
        static let keys: UInt32 = 0x6B65_7973
        static let ilst: UInt32 = 0x696C_7374
        static let hdlr: UInt32 = 0x6864_6C72
        static let data: UInt32 = 0x6461_7461
        /// "©day" — © is 0xA9, which is why types are four raw bytes and never a String.
        static let day: UInt32 = 0xA964_6179
    }

    static let plausibleFirst: Set<UInt32> = [
        Fourcc.ftyp, Fourcc.styp, Fourcc.moov, Fourcc.mdat,
        Fourcc.free, Fourcc.skip, Fourcc.wide, Fourcc.pnot, Fourcc.uuid,
    ]

    typealias Child = (type: UInt32, body: Range<Int64>)

    enum Piece {
        case box(type: UInt32, body: Int64, end: Int64)
        case need(Range<Int64>)
        case corrupt
    }

    /// Reads one atom header. Every guard here is what makes network bytes unable to crash
    /// or loop the walk: sizes below the header length, sizes past the parent, and 64-bit
    /// sizes that would overflow all land on `.corrupt`.
    static func piece(_ r: Reader, at offset: Int64, end parentEnd: Int64) -> Piece {
        guard offset >= 0, parentEnd - offset >= 8 else { return .corrupt }
        guard let size32 = r.u32(at: offset), let type = r.u32(at: offset + 4) else {
            return .need(offset ..< min(offset + 16, parentEnd))
        }
        if size32 == 0 { // "to the end of the enclosing space"
            return .box(type: type, body: offset + 8, end: parentEnd)
        }
        var headerLength: Int64 = 8
        var size = UInt64(size32)
        if size32 == 1 { // 64-bit size in the next 8 bytes
            guard let large = r.u64(at: offset + 8) else {
                return .need(offset ..< min(offset + 16, parentEnd))
            }
            size = large
            headerLength = 16
        }
        guard size >= UInt64(headerLength), size <= UInt64(parentEnd - offset) else {
            return .corrupt
        }
        return .box(type: type, body: offset + headerLength, end: offset + Int64(size))
    }

    /// Lists a container's children. Corruption mid-container keeps what was already read —
    /// a broken trailing atom must not hide an earlier, intact `meta`. Missing bytes fail
    /// with the range to fetch. The hop cap bounds the walk no matter what the bytes say.
    static func walk(_ r: Reader, from start: Int64,
                             to end: Int64) -> Walked {
        var kids: [Child] = []
        var cursor = start
        while cursor + 8 <= end, kids.count < 512 {
            switch piece(r, at: cursor, end: end) {
            case .need(let range): return .need(range)
            case .corrupt: return .kids(kids)
            case .box(let type, let body, let boxEnd):
                kids.append((type, body ..< boxEnd))
                cursor = boxEnd
            }
        }
        return .kids(kids)
    }

    enum Walked {
        case kids([Child])
        case need(Range<Int64>)
    }

    enum MetaStart {
        case at(Int64)
        case bail(Scan)
    }

    /// `meta` is a FullBox in ISO files (4 bytes of version/flags before the children) but a
    /// plain box in QuickTime ones. `hdlr` is the mandatory first child either way, so its
    /// position tells the two layouts apart.
    static func metaChildrenStart(_ r: Reader,
                                          _ meta: Range<Int64>) -> MetaStart {
        guard meta.upperBound - meta.lowerBound >= 12 else { return .bail(.absent) }
        guard let probe = r.u32(at: meta.lowerBound + 4) else {
            return .bail(.need(meta.lowerBound ..< min(meta.lowerBound + 12, meta.upperBound)))
        }
        return .at(probe == Fourcc.hdlr ? meta.lowerBound : meta.lowerBound + 4)
    }

    // MARK: - Bytes

    struct Reader {
        let slices: [Slice]
        let fileSize: Int64

        /// `nil` means "not fetched yet" — never "zero bytes". Reads must land inside one
        /// slice; the driver always fetches a needed range as one contiguous window.
        func bytes(at offset: Int64, count: Int) -> Data? {
            guard count > 0, offset >= 0, offset <= fileSize - Int64(count) else { return nil }
            for slice in slices {
                guard offset >= slice.offset,
                      offset - slice.offset <= Int64(slice.data.count - count) else { continue }
                let low = slice.data.startIndex + Int(offset - slice.offset)
                return slice.data[low ..< low + count]
            }
            return nil
        }

        func u32(at offset: Int64) -> UInt32? {
            bytes(at: offset, count: 4).map { UInt32(truncatingIfNeeded: be($0)) }
        }

        func u64(at offset: Int64) -> UInt64? {
            bytes(at: offset, count: 8).map(be)
        }

        private func be(_ data: Data) -> UInt64 {
            data.reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    // MARK: - Dates

    /// 1990 to two days from now. Below is 1904/epoch garbage; above, a drifted or unset
    /// camera clock — either would be worse on the timeline than falling back to mtime.
    private static func plausible(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince1970 >= 631_152_000 && date <= now.addingTimeInterval(172_800)
    }

    /// Apple writes "2021-06-19T17:12:43+0200"; other writers use "Z", fractions, a bare
    /// "YYYY-MM-DD", or a bare year. A bare year is rejected: not a capture date.
    private static func parse(_ stamp: String, now: Date) -> Date? {
        let text = stamp.trimmingCharacters(in: .whitespacesAndNewlines.union(["\0"]))
        guard text.count >= 10 else { return nil }

        let iso = ISO8601DateFormatter()
        var date = iso.date(from: text)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text)
        }
        if date == nil {
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
                fallback.dateFormat = format
                if let parsed = fallback.date(from: text) { date = parsed; break }
            }
        }
        guard let date, plausible(date, now: now) else { return nil }
        return date
    }
}

private extension [(type: UInt32, body: Range<Int64>)] {
    func first(_ type: UInt32) -> Range<Int64>? {
        first(where: { $0.type == type })?.body
    }
}

// MARK: - The Live Photo identifier

extension VideoDate {
    /// Same three-valued contract as `Scan`, carrying a string instead of a date. Kept
    /// separate rather than made generic: the date path has earned its shape through several
    /// real-file surprises, and a shared generic would put both at risk of one change.
    enum Text: Equatable, Sendable {
        case found(String)
        case absent
        case need(Range<Int64>)
    }

    /// `moov/meta` key `com.apple.quicktime.content.identifier` — the UUID a Live Photo's
    /// video shares with its still. Walks exactly the atoms the creation date already walks,
    /// so on a file being scanned for its date this costs no extra request.
    static func contentIdentifier(fileSize: Int64,
                                  fetch: (Range<Int64>) async throws -> Data) async throws
    -> String? {
        guard fileSize >= 16 else { return nil }
        var slices: [Slice] = []
        for _ in 0..<maxRequests {
            switch scanIdentifier(slices, fileSize: fileSize) {
            case .found(let text):
                return text
            case .absent:
                return nil
            case .need(let range):
                let lower = max(0, range.lowerBound)
                let upper = min(fileSize, max(range.upperBound, lower + chunk))
                guard lower < upper else { throw Undecided() }
                let data = try await fetch(lower ..< upper)
                guard Int64(data.count) >= range.upperBound - lower else { throw Undecided() }
                slices.append(Slice(offset: lower, data: data))
            }
        }
        throw Undecided()
    }

    static func scanIdentifier(_ slices: [Slice], fileSize: Int64) -> Text {
        let r = Reader(slices: slices, fileSize: fileSize)
        var cursor: Int64 = 0
        var hops = 0
        while cursor + 8 <= fileSize {
            hops += 1
            guard hops <= 1_000 else { return .absent }
            switch piece(r, at: cursor, end: fileSize) {
            case .need(let range): return .need(range)
            case .corrupt: return .absent
            case .box(let type, let body, let end):
                if cursor == 0, !plausibleFirst.contains(type) { return .absent }
                if type == Fourcc.moov { return moovIdentifier(r, body: body, end: end) }
                cursor = end
            }
        }
        return .absent
    }

    private static func moovIdentifier(_ r: Reader, body: Int64, end: Int64) -> Text {
        if end > body, end - body <= moovSlurp, r.bytes(at: body, count: Int(end - body)) == nil {
            return .need(body ..< end)
        }
        let kids: [Child]
        switch walk(r, from: body, to: end) {
        case .need(let range): return .need(range)
        case .kids(let found): kids = found
        }
        guard let meta = kids.first(Fourcc.meta) else { return .absent }

        let start: Int64
        switch metaChildrenStart(r, meta.lowerBound ..< meta.upperBound) {
        case .bail: return .absent
        case .at(let at): start = at
        }
        let inner: [Child]
        switch walk(r, from: start, to: meta.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): inner = found
        }
        guard let keys = inner.first(Fourcc.keys), let ilst = inner.first(Fourcc.ilst) else {
            return .absent
        }

        guard let rawCount = r.u32(at: keys.lowerBound + 4) else {
            return .need(keys.lowerBound ..< min(keys.lowerBound + 8, keys.upperBound))
        }
        guard rawCount <= 4_096, rawCount > 0 else { return .absent }

        var index: UInt32?
        var p = keys.lowerBound + 8
        for i in 1...rawCount {
            guard p + 8 <= keys.upperBound else { break }
            guard let entrySize = r.u32(at: p) else { return .need(p ..< keys.upperBound) }
            guard entrySize >= 8, Int64(entrySize) <= keys.upperBound - p else { break }
            if entrySize > 8 {
                guard let name = r.bytes(at: p + 8, count: Int(entrySize) - 8) else {
                    return .need(p ..< keys.upperBound)
                }
                if String(decoding: name, as: UTF8.self)
                    == "com.apple.quicktime.content.identifier" {
                    index = UInt32(i)
                    break
                }
            }
            p += Int64(entrySize)
        }
        guard let index else { return .absent }

        let entries: [Child]
        switch walk(r, from: ilst.lowerBound, to: ilst.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): entries = found
        }
        guard let entry = entries.first(index) else { return .absent }
        let payload: [Child]
        switch walk(r, from: entry.lowerBound, to: entry.upperBound) {
        case .need(let range): return .need(range)
        case .kids(let found): payload = found
        }
        guard let data = payload.first(Fourcc.data),
              data.upperBound - data.lowerBound > 8 else { return .absent }
        guard let text = r.bytes(at: data.lowerBound + 8,
                                 count: Int(data.upperBound - data.lowerBound - 8)) else {
            return .need(data.lowerBound ..< data.upperBound)
        }
        let value = String(decoding: text, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .absent : .found(value)
    }
}
