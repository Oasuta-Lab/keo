import Foundation

/// An iPhone Live Photo copied to a NAS arrives as two ordinary files: `IMG_4821.HEIC` and
/// `IMG_4821.MOV`, same stem, same folder. Nothing in the files says they belong together —
/// the pairing iOS does through `PHAsset` metadata is lost the moment they are copied.
///
/// So a library of Live Photos looks twice as full as it is, and every photo has a silent
/// grey twin next to it in the grid. This reunites them on the only evidence left: the name.
///
/// Pure on purpose. The same rule has to hold in three places — a fresh listing from the box,
/// a listing replayed from the index, and the SQL that marks the index — and a rule that
/// drifts between them shows a video in one and hides it in the other.
enum LivePhotos {
    /// Everything before the last dot. `IMG_4821.HEIC` and `IMG_4821.MOV` share `IMG_4821`.
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }

    /// Case-folded: a NAS can hold `IMG_4821.HEIC` next to `img_4821.mov`, and SMB shares are
    /// usually case-insensitive anyway.
    static func key(_ name: String) -> String { stem(name).lowercased() }

    /// How far apart the two halves' stored capture dates may sit and still be one moment.
    ///
    /// The halves themselves are written within seconds of each other. The slack is for the
    /// index, not for the files: the still's EXIF date is naive local time, reduced to an
    /// epoch through *this* device's timezone, while the video's `creationdate` carries the
    /// capture timezone — so a genuine pair shot abroad lands up to ~13 hours apart once both
    /// are epochs. No false pair the date can catch sits that close: two iPhones recycling the
    /// same counter do so months apart.
    static let captureTolerance: TimeInterval = 16 * 3600

    /// Whether these two can be the halves of one moment.
    ///
    /// Apple writes a shared UUID into both halves — MakerNote 17 on the still,
    /// `com.apple.quicktime.content.identifier` on the video — and Photos itself requires the
    /// two to be equal. The filename is only a convention laid on top, which is why two
    /// unrelated `IMG_0988` files were being folded into one.
    ///
    /// Three verdicts, from strongest evidence to weakest:
    /// - both halves read and both carrying (`""` means read and absent, `nil` never read):
    ///   the identifiers decide, equal or not.
    /// - one half read and carrying, the other read and carrying none: suspect. A Live half
    ///   never travels without its identifier *unless* a re-encode stripped it — and then the
    ///   two capture dates still agree. When both dates are known they decide; a missing date
    ///   keeps the pair, because wrongly hiding a video loses it while wrongly showing a
    ///   duplicate is cosmetic — and the index converges as the dates get read.
    /// - anything less read than that: the name rule stays in charge, exactly as before.
    static func compatible(still: Item, video: Item) -> Bool {
        guard let photo = still.contentID, let clip = video.contentID else { return true }
        if !photo.isEmpty && !clip.isEmpty { return photo == clip }
        guard photo.isEmpty != clip.isEmpty,
              let a = still.captureDate, let b = video.captureDate else { return true }
        return abs(a.timeIntervalSince(b)) <= captureTolerance
    }

    /// Splits a folder's media into what the grid shows and what hides behind it.
    ///
    /// A video is a companion only when a *still* of the same stem sits in the same folder.
    /// A lone `.MOV` is a video like any other and stays visible — that is the common case
    /// for anything not shot on an iPhone, and hiding it would lose it altogether.
    static func pair(_ media: [Item]) -> (visible: [Item], companions: [Item.ID: Item]) {
        let stills = media.filter { $0.kind == .image }
        guard !stills.isEmpty else { return (media, [:]) }

        // All the stills of a stem, not just the first: one name can be worn by several
        // moments, and the video belongs to whichever of them claims it.
        var stillsByKey: [String: [Item]] = [:]
        for still in stills { stillsByKey[key(still.name), default: []].append(still) }

        var companions: [Item.ID: Item] = [:]
        var visible: [Item] = []
        visible.reserveCapacity(media.count)
        for item in media {
            guard item.kind == .video,
                  let candidates = stillsByKey[key(item.name)],
                  let still = candidates.first(where: { compatible(still: $0, video: item) })
            else {
                visible.append(item)
                continue
            }
            // One still keeps one companion: a second video of the same stem stays visible
            // rather than quietly replacing the first.
            if companions[still.id] == nil {
                companions[still.id] = item
            } else {
                visible.append(item)
            }
        }
        return (visible, companions)
    }
}
