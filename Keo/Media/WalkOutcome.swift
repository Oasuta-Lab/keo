import Foundation

/// Decides whether an indexing pass may be called complete.
///
/// This verdict is load-bearing: only a complete pass sweeps away what it did not see, claims
/// the index is up to date, and drops the intent to resume. Getting it wrong deleted folders
/// the pass had merely failed to reach — a suspended app, whose every request failed, looked
/// exactly like a pass that had walked the whole NAS and found it empty.
enum WalkOutcome {
    static func isComplete(cancelled: Bool, visited: Int, limit: Int,
                           listingFailures: Int, queueEmpty: Bool) -> Bool {
        guard !cancelled else { return false }           // interrupted on purpose
        guard visited < limit else { return false }      // the loop backstop fired
        guard listingFailures == 0 else { return false } // a folder we never saw may still exist
        return queueEmpty                               // nothing left to visit
    }

    /// Only a complete pass may delete what it did not encounter.
    static func maySweep(cancelled: Bool, visited: Int, limit: Int,
                         listingFailures: Int, queueEmpty: Bool) -> Bool {
        isComplete(cancelled: cancelled, visited: visited, limit: limit,
                   listingFailures: listingFailures, queueEmpty: queueEmpty)
    }
}
