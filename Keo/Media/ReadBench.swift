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

    /// The gate before pairing Live Photos on Apple's identifier rather than on filenames.
    ///
    /// The identifier lives in the same metadata blob as the capture date, so in principle a
    /// 24 KB prefix that yields one yields the other. "In principle" is what this repository
    /// has learned to distrust: the date itself was found in only 38.9 % of 4 KB prefixes
    /// before anyone measured it. So it is measured, on real photos, before a line of the
    /// pairing rule is written.
    ///
    /// Reads nothing the indexer does not already read, and writes nothing anywhere.
    static func identifiers(folder: String, client: FreeboxClient, sample: Int = 120) async {
        let contents: FolderContents
        do {
            contents = try await client.list(folder)
        } catch {
            trace("cid: listing failed \(folder): \(error.localizedDescription)")
            return
        }

        let stills = contents.media.filter { $0.kind == .image }
        guard !stills.isEmpty else {
            trace("cid: aucune photo dans \(folder)")
            return
        }
        let pool = Array(stills.shuffled().prefix(sample))
        trace("cid: \(folder), \(pool.count) photos sur \(stills.count)")

        var dated = 0, identified = 0, deepDated = 0, deepIdentified = 0, failed = 0
        for item in pool {
            guard let head = try? await client.bytes(item.path, prefix: prefix) else {
                failed += 1
                continue
            }
            let date = ImageDecoding.captureDate(prefix: head)
            let cid = ImageDecoding.contentIdentifier(prefix: head)
            if date != nil { dated += 1 }
            if cid != nil { identified += 1 }

            // The second window the indexer already falls back to, so the comparison is
            // against what Keo actually does and not against a prefix it never reads.
            guard date == nil || cid == nil, item.size > Int64(prefix),
                  let deeper = try? await client.bytes(item.path, prefix: deepPrefix) else {
                if date != nil { deepDated += 1 }
                if cid != nil { deepIdentified += 1 }
                continue
            }
            if ImageDecoding.captureDate(prefix: deeper) != nil { deepDated += 1 }
            if ImageDecoding.contentIdentifier(prefix: deeper) != nil { deepIdentified += 1 }
        }

        let n = max(pool.count - failed, 1)
        trace(String(format: "cid: 24 Ko — date %d/%d (%.1f %%), identifiant %d/%d (%.1f %%)",
                     dated, n, Double(dated) * 100 / Double(n),
                     identified, n, Double(identified) * 100 / Double(n)))
        trace(String(format: "cid: 128 Ko — date %d/%d (%.1f %%), identifiant %d/%d (%.1f %%)",
                     deepDated, n, Double(deepDated) * 100 / Double(n),
                     deepIdentified, n, Double(deepIdentified) * 100 / Double(n)))
        trace("cid: \(failed) illisibles")
    }

    /// The decisive measurement: on pairs the current rule already made, do the two halves
    /// carry Apple's shared identifier, and does it agree?
    ///
    /// The previous probe answered the wrong question. It sampled photos at random and found
    /// an identifier on 80.8 % of them — which is a fact about how many photos are Live, not
    /// about whether the identifier can be read. What decides the rule is this: of the pairs
    /// Keo currently shows as one moment, how many would survive a switch to identity, and
    /// how many are coincidences of name like the IMG_0988 the owner found.
    static func pairs(folder: String, client: FreeboxClient, sample: Int = 60) async {
        let contents: FolderContents
        do {
            contents = try await client.list(folder)
        } catch {
            trace("paires: listing failed \(folder): \(error.localizedDescription)")
            return
        }

        let pairs = contents.companions.compactMap { still, video -> (Item, Item)? in
            guard let photo = contents.media.first(where: { $0.id == still }) else { return nil }
            return (photo, video)
        }
        guard !pairs.isEmpty else {
            trace("paires: aucune paire dans \(folder)")
            return
        }
        let pool = Array(pairs.shuffled().prefix(sample))
        trace("paires: \(folder), \(pool.count) paires sur \(pairs.count)")

        var agree = 0, differ = 0, stillOnly = 0, videoOnly = 0, neither = 0, unreadable = 0
        for (still, video) in pool {
            guard let head = try? await client.bytes(still.path, prefix: prefix) else {
                unreadable += 1
                continue
            }
            var photoID = ImageDecoding.contentIdentifier(prefix: head)
            if photoID == nil, still.size > Int64(prefix),
               let deeper = try? await client.bytes(still.path, prefix: deepPrefix) {
                photoID = ImageDecoding.contentIdentifier(prefix: deeper)
            }

            let clipID = try? await VideoDate.contentIdentifier(fileSize: video.size) { range in
                try await client.bytes(video.path, range: range)
            }

            switch (photoID, clipID ?? nil) {
            case let (a?, b?) where a == b: agree += 1
            case (_?, _?):
                differ += 1
                // Named, because this is the case the owner reported and the one worth
                // seeing with your own eyes before trusting a rule built on it.
                trace("paires: désaccord \(still.name) / \(video.name)")
            case (_?, nil): stillOnly += 1
            case (nil, _?): videoOnly += 1
            case (nil, nil): neither += 1
            }
        }

        trace("paires: identiques \(agree), différents \(differ), photo seule \(stillOnly), "
            + "vidéo seule \(videoOnly), aucun des deux \(neither), illisibles \(unreadable)")
    }

    /// The indexer's second window, so the measurement matches what it would really do.
    static let deepPrefix = 128 << 10

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
