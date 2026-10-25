import Foundation

/// What the grid has asked to be warmed up, and how many drains should be working on it.
///
/// A scroll hint **replaces** the backlog instead of extending it. Appending looked harmless
/// and was not: every cell coming on screen queued twenty-four more rows, so scrolling past a
/// thousand cells left tens of thousands of fetches pending — all of them for rows that had
/// long since left the screen, and all of them ahead of whatever the reader had actually
/// stopped on. Arriving far down a folder therefore landed on empty cells, and the viewer,
/// which asks the same pipeline for its first image, waited behind the same queue.
///
/// Dropping the rows passed over costs nothing: nobody is looking at them, and if the reader
/// scrolls back the cache answers from disk.
struct PrefetchWindow {
    /// How many fetches run ahead of the reader. Two, so a hint is never starved waiting for
    /// a single drain, and visible cells keep the larger share of the connections.
    static let drainLimit = 2

    private(set) var pending: [Item] = []
    private(set) var drains = 0

    /// Takes the new window and returns how many drains to start — zero when enough are
    /// already running, since a running drain will pick the new window up on its next turn.
    mutating func replace(with items: [Item]) -> Int {
        pending = items.filter(\.isMedia)
        guard !pending.isEmpty else { return 0 }
        let starting = Self.drainLimit - drains
        drains += starting
        return starting
    }

    /// The next row to warm up. `nil` ends the drain **and gives its slot back**, so the next
    /// hint knows to start one again; a drain that stops without releasing its slot would
    /// leave the window permanently unattended.
    mutating func next() -> Item? {
        guard !pending.isEmpty else {
            drains -= 1
            return nil
        }
        return pending.removeFirst()
    }
}
