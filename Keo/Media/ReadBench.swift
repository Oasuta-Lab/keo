#if DEBUG
import Foundation

/// Measures what the box will actually give us, so `Indexer.parallel` stops being a guess.
///
/// Three was picked cautiously and never checked. The right number is a property of the box
/// and the network, not of the code, so it has to be measured rather than reasoned about —
/// the same lesson the indexing lifecycle already taught us the expensive way.
///
/// Strictly read-only, like everything else here: it reads the same byte prefixes the indexer
/// reads and writes nothing, not even to the local index.
enum ReadBench {
    struct Run: Sendable {
        let parallel: Int
        let files: Int
        let bytes: Int64
        let seconds: Double
        let failures: Int

        var filesPerSecond: Double { seconds > 0 ? Double(files) / seconds : 0 }
        var megabitsPerSecond: Double {
            seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
        }

        var line: String {
            String(format: "parallel=%2d  %3d fichiers en %5.2f s  %5.1f f/s  %5.1f Mb/s  %d échecs",
                   parallel, files, seconds, filesPerSecond, megabitsPerSecond, failures)
        }
    }

    /// 24 KB is what the indexer asks for on a photo, so the measurement matches the workload.
    static let prefix = 24 << 10

    /// Each level gets its **own slice** of files. Replaying the same files would measure the
    /// box's cache and the levels would all look fast in the order they ran.
    ///
    /// Two more defences against reading noise as signal. The window into the folder starts at
    /// a random offset, so running the bench twice samples different files instead of
    /// re-reading what the box just cached. And the levels run in a random order, so a network
    /// that drifts during the measurement no longer systematically flatters whichever level
    /// happened to go first.
    ///
    /// The window is **contiguous**, not a shuffle of the whole folder. Shuffling made every
    /// level land on 30 f/s whatever the concurrency: scattered reads across eight thousand
    /// photos are seek-bound on the box's disk, which is not the workload. The indexer reads a
    /// folder in listing order, so the measurement has to as well.
    static func run(folder: String, client: FreeboxClient,
                    levels: [Int] = [1, 2, 3, 4, 6, 8, 12],
                    perLevel: Int = 80) async -> [Run] {
        let contents: FolderContents
        do {
            contents = try await client.list(folder)
        } catch {
            trace("bench: listing failed \(folder): \(error.localizedDescription)")
            return []
        }

        // Photos only: a video's date costs a variable number of range requests, which would
        // measure the parser rather than the concurrency.
        let ordered = contents.media.filter { $0.kind == .image }
        let needed = levels.count * perLevel
        guard ordered.count >= needed else {
            trace("bench: \(folder) n'a que \(ordered.count) photos, il en faut \(needed)")
            return []
        }

        let start = Int.random(in: 0...(ordered.count - needed))
        let pool = Array(ordered[start..<(start + needed)])
        trace("bench: \(folder), \(ordered.count) photos, fenêtre à \(start), "
            + "\(perLevel) par niveau, ordre des niveaux tiré au sort")
        var runs: [Run] = []
        for (index, level) in levels.shuffled().enumerated() {
            let slice = Array(pool[(index * perLevel)..<((index + 1) * perLevel)])
            let run = await measure(slice, parallel: level, client: client)
            trace("bench: " + run.line)
            runs.append(run)
            if Task.isCancelled { break }
        }

        runs.sort { $0.parallel < $1.parallel }
        if let best = runs.max(by: { $0.filesPerSecond < $1.filesPerSecond }) {
            trace("bench: meilleur débit à parallel=\(best.parallel) "
                  + String(format: "(%.1f f/s)", best.filesPerSecond)
                  + " — à confirmer sur plusieurs passages")
        }
        return runs
    }

    private static func measure(_ items: [Item], parallel: Int,
                                client: FreeboxClient) async -> Run {
        let started = Date()
        var bytes: Int64 = 0
        var failures = 0

        // Same shape as the indexer's own loop: a fixed window that refills as each read
        // lands, not a batch barrier — otherwise one slow file would pace the whole level.
        await withTaskGroup(of: Int?.self) { group in
            var next = 0
            func feed() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    try? await client.bytes(item.path, prefix: prefix).count
                }
            }
            for _ in 0..<min(parallel, items.count) { feed() }
            while let outcome = await group.next() {
                if let count = outcome { bytes += Int64(count) } else { failures += 1 }
                feed()
            }
        }

        return Run(parallel: parallel, files: items.count, bytes: bytes,
                   seconds: Date().timeIntervalSince(started), failures: failures)
    }
}
#endif
