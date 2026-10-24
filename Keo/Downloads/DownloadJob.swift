import Foundation

/// Progress across a batch. Separate from `Downloader` so the arithmetic stays testable
/// without dragging UIKit in.
struct DownloadJob {
    var total: Int
    var completed: Int
    var currentName: String
    var currentFraction: Double

    /// Finished files plus however far the current one has got.
    var fraction: Double {
        guard total > 0 else { return 0 }
        let advanced = Double(completed) + currentFraction
        return min(max(advanced / Double(total), 0), 1)
    }

    /// 1-based position of the file being fetched, never past the total.
    var position: Int { min(completed + 1, total) }
}
