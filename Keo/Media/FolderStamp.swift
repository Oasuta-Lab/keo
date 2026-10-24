import Foundation

/// Decides whether a folder can be skipped on a later indexing pass.
///
/// A directory's modification date moves as soon as an entry is added or removed, so comparing
/// it against the date recorded when the folder was last fully read is what makes new photos
/// get picked up without re-reading the ones already known.
enum FolderStamp {
    /// Filesystem timestamps come back with sub-second noise; a second of slack avoids
    /// re-listing a folder that has not actually changed.
    static let tolerance: TimeInterval = 1

    static func isUnchanged(recorded: Double?, modified: Date?) -> Bool {
        guard let recorded, let modified else { return false }
        return abs(recorded - modified.timeIntervalSince1970) < tolerance
    }

    /// `nil` means "do not record": a folder with no date can never be trusted as unchanged.
    static func stamp(for modified: Date?) -> Double? {
        modified?.timeIntervalSince1970
    }
}

extension FolderStamp {
    /// Everything recorded when a folder has been read end to end.
    struct Completion: Sendable {
        let modified: Date?
        let childCount: Int?
        let mediaCount: Int?
        let bytes: Int64?
    }
}

/// Summary shown on a folder tile. Counted over the whole subtree.
struct FolderStats: Equatable, Sendable {
    let mediaCount: Int
    let bytes: Int64?
    let earliest: Date?
    let latest: Date?

    /// "2019 – 2024", or a single year, or nothing when no date is known yet.
    var span: String? {
        guard let earliest, let latest else { return nil }
        let calendar = Calendar.current
        let first = calendar.component(.year, from: earliest)
        let last = calendar.component(.year, from: latest)
        return first == last ? "\(first)" : "\(first) – \(last)"
    }
}
