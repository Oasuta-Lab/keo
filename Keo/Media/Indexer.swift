import Foundation
import SwiftUI
import UIKit

/// The one place that reads capture dates off the NAS.
///
/// There used to be two: a per-folder scan and a background walk, which could work the same
/// folder at once and double the traffic to the box. This is a single serial worker with a
/// queue the open folder jumps to the front of.
/// Lifecycle tracing, debug builds only. Three rounds of plausible-but-wrong fixes is enough:
/// the next change to this file should be driven by what the device actually reports.
///
/// Also written to the app container, because `devicectl … --console` keeps dying — the
/// session ends the moment the app is relaunched from the home screen, and it has already
/// swallowed two measurements. The file survives that, and comes back with:
///
///     xcrun devicectl device copy from --device <UDID> \
///       --domain-type appDataContainer --domain-identifier com.oasutalab.keo \
///       --source "Library/Application Support/Keo/trace.log" --destination /tmp/
func trace(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "[keo] \(message())"
    print(line)
    TraceFile.append(line)
    #endif
}

#if DEBUG
/// Append-only, size-capped, and silent on failure: a diagnostic that can break the app it
/// diagnoses is worse than no diagnostic.
private enum TraceFile {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()
    private static let cap: UInt64 = 2 << 20

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        if handle == nil {
            guard let folder = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Keo", isDirectory: true) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("trace.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            // Start over rather than grow without bound; nobody reads a week-old trace.
            if let size = try? handle?.seekToEnd(), size > cap {
                try? handle?.truncate(atOffset: 0)
            }
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }
}
#endif

@MainActor
final class Indexer: ObservableObject {
    /// What went wrong, and where. A bare counter tells you something failed but never what,
    /// which is no help at all when one folder out of eighty is unreachable.
    struct Problem: Identifiable, Equatable, Sendable {
        enum Trouble: Equatable, Sendable {
            case folderUnreachable   // could not even be listed
            case fileUnreadable      // listed, but its bytes would not come
        }

        var id: String { path }
        let path: String
        let reason: String
        let trouble: Trouble

        var name: String { (path as NSString).lastPathComponent }
    }

    struct Progress: Equatable {
        var folder = "/"
        var foldersVisited = 0
        var foldersSkipped = 0
        var mediaFound = 0
        var datesRead = 0
        var adopted = 0
        var unreadable = 0
        /// Folders that could not even be listed. Any of these makes the pass incomplete.
        var unreachable = 0
        /// The first few in detail. Bounded: a box that is entirely gone would otherwise
        /// collect thousands of identical entries.
        var problems: [Problem] = []

        mutating func note(_ problem: Problem) {
            guard problems.count < Progress.problemLimit,
                  !problems.contains(where: { $0.path == problem.path }) else { return }
            problems.append(problem)
        }

        static let problemLimit = 60
        /// Files read but carrying no capture date at all.
        var dateless = 0
        /// Current folder only. A global bar moves by 0.17 % per batch on a 14 600 photo
        /// folder, which reads as frozen.
        var folderDone = 0
        var folderTotal = 0
        var indexedOverall = 0

        var folderFraction: Double {
            folderTotal == 0 ? 0 : min(Double(folderDone) / Double(folderTotal), 1)
        }
    }

    /// Dates discovered for one folder, handed to whoever is displaying it.
    struct Resolution: Equatable {
        let folder: String
        let dates: [Item.ID: Date]
    }

    enum State: Equatable {
        case idle
        case running(Progress)
        /// Interrupted — by backgrounding, or by the user. Saying "finished" here was a lie
        /// that made an unfinished index look complete.
        case paused(Progress)
        case finished(Progress)

        var progress: Progress? {
            switch self {
            case .idle: return nil
            case .running(let p), .paused(let p), .finished(let p): return p
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isPaused: Bool {
            if case .paused = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var resolution: Resolution?
    @Published var failure: String?

    @AppStorage("lastIndexedAt") private var lastIndexedAt: Double = 0

    /// Measured on the real box, four passes of `ReadBench` over 14 595 photos: 1 is last in
    /// every pass, 2 and 3 sit below a plateau that runs from 4 to 12, and 4 ties for the best
    /// rank. Picked over 8, which ties with it, because the gain is noise and the smaller
    /// number leaves more of the box to the thumbnail pipeline — the user is looking at the
    /// grid, and that is the one cost the bench cannot see.
    private static let parallel = 4
    /// Measured on 120 photos from a real library: 4 KB found only 39 % of the dates, 16 KB
    /// 92 %, and 24 KB 99 % — for the same average transfer as 16 KB, since a miss costs a
    /// second request. Past 24 KB the curve is flat.
    nonisolated private static let prefixBytes = 24 << 10
    /// Second try, for the last 1 %. On that same sample, no photo revealed a date only in
    /// the full file: whatever 128 KB misses is genuinely undated.
    nonisolated private static let deepPrefixBytes = 128 << 10
    private static let publishEvery = 20
    /// Backstop against a symlink loop turning this into an infinite walk.
    private static let folderLimit = 5_000
    /// Consecutive unreachable folders before concluding the box is gone.
    private static let giveUpAfter = 3

    private enum Job {
        case walk(root: String, client: FreeboxClient, scope: Scope?)
        case folder(path: String, items: [Item], client: FreeboxClient)
    }

    private var queue: [Job] = []
    private var runner: Task<Void, Never>?
    /// Identifies the current worker. A cancelled one must not pick up newly queued work, nor
    /// decide the final state after a fresh worker has taken over.
    private var runToken = 0
    private var walkCompleted = false
    private var observers: [NSObjectProtocol] = []
    /// Survives a relaunch: iOS may terminate a suspended app outright, and an interrupted
    /// index must still know it has somewhere to pick up.
    @AppStorage("resumeIndexing") private var resumeWanted = false
    @AppStorage("resumeIndexingRoot") private var resumeRoot = FreeboxClient.rootPath
    private var background: UIBackgroundTaskIdentifier = .invalid

    var lastRun: Date? {
        lastIndexedAt > 0 ? Date(timeIntervalSince1970: lastIndexedAt) : nil
    }

    // MARK: Entry points

    enum Scope {
        /// List every folder again, but keep every date already read.
        case recheck
        /// Throw away every date and read them all again.
        case rebuild
    }

    func start(from root: String = FreeboxClient.rootPath, client: FreeboxClient,
               scope: Scope? = nil) {
        // A state left saying "running" with nothing behind it must not block a restart.
        if isStalled, case .running(let progress) = state { state = .paused(progress) }
        guard !state.isRunning else { return }

        trace("start root=\(root) scope=\(String(describing: scope)) "
            + "state=\(state) stalled=\(isStalled) queue=\(queue.count)")
        resumeRoot = root
        resumeWanted = true
        queue.append(.walk(root: root, client: client, scope: scope))
        watchAppState(root: root, client: client)
        pump()
    }

    /// The folder on screen goes to the front: whoever is looking at it is waiting.
    func prioritise(folder: String, items: [Item], client: FreeboxClient) {
        guard !items.isEmpty else { return }
        queue.insert(.folder(path: folder, items: items, client: client), at: 0)
        pump()
    }

    func stop() {
        resumeWanted = false
        queue.removeAll()
        halt()
    }

    /// Picks up an index interrupted by a suspension or a termination. Safe to call on every
    /// launch: it does nothing unless there is something to resume.
    func resumeIfInterrupted(client: FreeboxClient) {
        if case .finished = state { return }      // a completed pass is not an interruption
        guard resumeWanted, !state.isRunning || isStalled else { return }
        start(from: resumeRoot, client: client)
    }

    /// True when the app believes work is in flight but no worker is actually alive — the
    /// state a suspension used to leave behind.
    var isStalled: Bool { state.isRunning && runner == nil }

    // MARK: Running

    private func pump() {
        guard runner == nil, !queue.isEmpty else { return }
        beginBackgroundGrace()

        runToken += 1
        let token = runToken
        walkCompleted = false
        trace("pump token=\(token) queue=\(queue.count)")

        runner = Task { [weak self] in
            while let job = await self?.nextJob(token) {
                switch job {
                case .walk(let root, let client, let scope):
                    await self?.walk(root: root, client: client, scope: scope)
                case .folder(let path, let items, let client):
                    await self?.scanOne(path: path, items: items, client: client)
                }
                if Task.isCancelled { break }
            }
            await self?.finishRun(token)
        }
    }

    private func nextJob(_ token: Int) -> Job? {
        guard token == runToken else {
            trace("nextJob refused: token=\(token) current=\(runToken)")
            return nil
        }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func finishRun(_ token: Int) {
        trace("finishRun token=\(token) current=\(runToken) completed=\(walkCompleted)")
        guard token == runToken else { return }   // a superseded worker decides nothing
        if walkCompleted { resumeWanted = false }
        runner = nil
        await_checkpoint()
        endBackgroundGrace()
        if case .running(let progress) = state {
            state = walkCompleted ? .finished(progress) : .paused(progress)
        }
    }

    private func await_checkpoint() {
        Task { await IndexStore.shared.checkpoint() }
    }

    private func halt() {
        trace("halt state=\(state)")
        runToken += 1          // whatever is still running is now superseded
        runner?.cancel()
        runner = nil
        endBackgroundGrace()
        if case .running(let progress) = state { state = .paused(progress) }
    }

    // MARK: Jobs

    private func walk(root: String, client: FreeboxClient, scope: Scope?) async {
        var progress = state.progress ?? Progress()
        // Per-pass counters: carried over, they counted the same folders again at every
        // resume — 14 618 media became 29 213 then 43 808 without a single new file.
        progress.foldersVisited = 0
        progress.foldersSkipped = 0
        progress.mediaFound = 0
        progress.unreachable = 0
        progress.problems.removeAll()
        progress.folder = root
        state = .running(progress)

        do {
            switch scope {
            case .recheck: try await IndexStore.shared.forgetWalk()
            case .rebuild: try await IndexStore.shared.forgetEverything()
            case nil: break
            }
            let generation = try await IndexStore.shared.beginGeneration()

            var pending: [(path: String, modified: Date?, childCount: Int?)] =
                [(root, nil, nil)]
            var visited = 0
            var listingFailures = 0
            var consecutiveFailures = 0

            while !pending.isEmpty, !Task.isCancelled, visited < Self.folderLimit {
                let folder = pending.removeFirst()
                visited += 1

                // Untouched since it was fully read, and nothing nested under it: only then
                // is skipping the listing safe. A folder with children must still be listed,
                // or the walk never discovers them and declares itself finished two folders in.
                let untouched = try await IndexStore.shared.isUnchanged(
                    folder.path, modified: folder.modified, childCount: folder.childCount
                )
                let hasChildren = try await IndexStore.shared.hasChildFolders(folder.path)
                if untouched, !hasChildren {
                    try await IndexStore.shared.touchSubtree(folder.path, generation: generation)
                    progress.foldersSkipped += 1
                    state = .running(progress)
                    continue
                }

                progress.folder = folder.path
                progress.folderDone = 0
                progress.folderTotal = 0
                state = .running(progress)

                let contents: FolderContents
                do {
                    contents = try await client.list(folder.path, order: .name)
                    consecutiveFailures = 0
                } catch {
                    trace("list FAILED \(folder.path): \(error.localizedDescription)")
                    // A failed listing is not an empty folder. Counting it keeps the pass from
                    // calling itself complete — and from sweeping away everything it never
                    // reached, which is how a suspended app used to destroy its own index.
                    listingFailures += 1
                    consecutiveFailures += 1
                    progress.unreachable += 1
                    progress.note(Problem(path: folder.path,
                                          reason: error.localizedDescription,
                                          trouble: .folderUnreachable))
                    state = .running(progress)

                    // The box is gone, or we are being suspended: stop rather than grind the
                    // whole tree into failures.
                    if consecutiveFailures >= Self.giveUpAfter { break }
                    continue
                }
                pending.append(contentsOf: contents.folders.map {
                    ($0.path, $0.modified, $0.childCount)
                })
                progress.foldersVisited += 1
                progress.mediaFound += contents.media.count
                if contents.media.count > 50 {
                    let videos = contents.media.filter { $0.kind == .video }.count
                    trace("folder \(folder.path): media=\(contents.media.count) "
                        + "images=\(contents.media.count - videos) videos=\(videos) "
                        + "docs=\(contents.documents.count)")
                }

                let completion = FolderStamp.Completion(
                    modified: folder.modified,
                    childCount: contents.folders.count + contents.media.count
                              + contents.documents.count,
                    mediaCount: contents.media.count,
                    // Everything the folder holds, documents included: the tile answers
                    // "how heavy is this folder", not "how heavy are its photos".
                    bytes: (contents.media + contents.documents)
                        .reduce(Int64(0)) { $0 + $1.size }
                )
                // Documents travel with the photos: they are what makes a folder openable
                // from the cache and findable by name. They are recorded, never read.
                await index(contents.media + contents.documents, in: folder.path,
                            generation: generation, stamp: completion,
                            client: client, progress: &progress)
            }

            // Only a pass that truly saw everything may decide what has disappeared.
            let complete = WalkOutcome.isComplete(
                cancelled: Task.isCancelled, visited: visited, limit: Self.folderLimit,
                listingFailures: listingFailures, queueEmpty: pending.isEmpty
            )
            trace("walk end complete=\(complete) cancelled=\(Task.isCancelled) "
                + "visited=\(visited) failures=\(listingFailures) "
                + "pendingEmpty=\(pending.isEmpty) skipped=\(progress.foldersSkipped)")
            if complete {
                try await IndexStore.shared.sweepFolders(generation: generation)
                lastIndexedAt = Date().timeIntervalSince1970
                walkCompleted = true
                resumeWanted = false   // nothing left to pick up
            }
            progress.indexedOverall = (try? await IndexStore.shared.fileCount()) ?? 0
            // Never republish `.running` after a pause: that is what left the app claiming to
            // work with nobody behind it.
            if !Task.isCancelled { state = .running(progress) }
        } catch {
            trace("walk threw: \(error.localizedDescription)")
            failure = error.localizedDescription
        }
    }

    private func scanOne(path: String, items: [Item], client: FreeboxClient) async {
        var progress = state.progress ?? Progress()
        progress.folder = path
        progress.folderDone = 0
        progress.folderTotal = items.count
        state = .running(progress)

        do {
            let generation = try await IndexStore.shared.beginGeneration()
            await index(items, in: path, generation: generation, stamp: nil,
                        client: client, progress: &progress)
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Reading

    /// Reads whatever is still unknown, in batches, and hands the folder's dates back.
    ///
    /// `files` is the whole listing, documents included. Only the media are read: there is no
    /// capture date to find in a PDF, and fetching its first kilobytes would buy nothing.
    private func index(_ files: [Item], in folder: String, generation: Int64,
                       stamp: FolderStamp.Completion?,
                       client: FreeboxClient, progress: inout Progress) async {
        guard let store = try? await IndexStore.shared.unread(files, in: folder) else { return }
        var todo = store.filter(\.isMedia)
        let filed = store.filter { !$0.isMedia }
        var discovered: [Item.ID: Date] = [:]

        // A folder renamed or moved keeps its photos: the same name and size elsewhere in the
        // index hands us the date for free, instead of hours of re-reading.
        if let inherited = try? await IndexStore.shared.adopt(todo), !inherited.isEmpty {
            let adopted = todo.filter { inherited[$0.id] != nil }
            try? await IndexStore.shared.commit(
                adopted.map { ($0, inherited[$0.id]) }, in: folder, generation: generation
            )
            discovered.merge(inherited) { _, new in new }
            progress.adopted += adopted.count
            todo.removeAll { inherited[$0.id] != nil }
        }

        progress.folderTotal = todo.count
        state = .running(progress)

        var batch: [(item: Item, capture: Date?)] = []
        var failures = 0
        var done = 0
        var published = 0

        func flush(stamping: Bool) async {
            guard !batch.isEmpty || stamping else { return }
            do {
                try await IndexStore.shared.commit(
                    batch, in: folder, generation: generation,
                    stamp: stamping ? stamp : nil,
                    present: stamping ? files : [], sweep: stamping
                )
                batch.removeAll(keepingCapacity: true)
            } catch {
                failure = error.localizedDescription
            }
        }

        for document in filed {
            batch.append((document, nil))
            if batch.count >= IndexStore.batchSize { await flush(stamping: false) }
        }

        if !todo.isEmpty {
            await withTaskGroup(of: (Item, Result<Date?, Error>).self) { group in
                var next = 0
                func feed() {
                    guard next < todo.count else { return }
                    let item = todo[next]
                    next += 1
                    group.addTask {
                        do {
                            if item.kind == .video {
                                // Range-driven atom walk; `VideoDate.Undecided` lands in the
                                // failure branch below, so a truncated read stays retryable
                                // instead of becoming a permanent "no date".
                                let date = try await VideoDate.capture(fileSize: item.size) {
                                    try await client.bytes(item.path, range: $0)
                                }
                                return (item, .success(date))
                            }
                            let head = try await client.bytes(item.path, prefix: Self.prefixBytes)
                            if let date = ImageDecoding.captureDate(prefix: head) {
                                return (item, .success(date))
                            }
                            guard item.size > Int64(Self.prefixBytes) else {
                                return (item, .success(nil))
                            }
                            let deeper = try await client.bytes(item.path,
                                                                prefix: Self.deepPrefixBytes)
                            return (item, .success(ImageDecoding.captureDate(prefix: deeper)))
                        } catch {
                            return (item, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(Self.parallel, todo.count) { feed() }

                while let (item, outcome) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }

                    switch outcome {
                    case .success(let capture):
                        batch.append((item, capture))
                        if let capture {
                            discovered[item.id] = capture
                        } else {
                            progress.dateless += 1
                            if progress.dateless <= 12 {
                                trace("dateless \(item.kind) \(item.name) \(item.size) octets")
                            }
                        }
                        progress.datesRead += 1
                    case .failure(let error):
                        // Left unknown on purpose: a dropped connection must be retried, never
                        // recorded as "this photo has no date".
                        failures += 1
                        progress.unreadable += 1
                        progress.note(Problem(path: item.path,
                                              reason: error.localizedDescription,
                                              trouble: .fileUnreadable))
                    }

                    done += 1
                    if batch.count >= IndexStore.batchSize { await flush(stamping: false) }
                    if done - published >= Self.publishEvery {
                        published = done
                        progress.folderDone = done
                        state = .running(progress)
                    }
                    feed()
                }
            }
        }

        // The completion stamp travels in the same transaction as the last batch, so it can
        // never claim more than what is actually written.
        await flush(stamping: failures == 0 && !Task.isCancelled)

        progress.folderDone = done
        progress.indexedOverall = (try? await IndexStore.shared.fileCount())
            ?? progress.indexedOverall
        // Same rule as `walk`: never republish `.running` once cancelled, or the app goes back
        // to claiming it is working with nobody behind it.
        if !Task.isCancelled { state = .running(progress) }

        if !discovered.isEmpty {
            resolution = Resolution(folder: folder, dates: discovered)
        }
    }

    // MARK: App lifecycle

    /// iOS suspends a backgrounded app and terminates it if it is still busy. Pause, commit,
    /// and pick up again on return.
    private func watchAppState(root: String, client: FreeboxClient) {
        guard observers.isEmpty else { return }
        let centre = NotificationCenter.default

        observers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronous on purpose. Scheduling a Task here loses the race: the handler
            // returns, iOS suspends the process, and the Task never runs — so the work was
            // never paused and nothing was ever marked resumable.
            MainActor.assumeIsolated {
                guard let self else { return }
                trace("background: running=\(self.state.isRunning)")
                guard self.state.isRunning else { return }
                self.resumeRoot = root
                self.resumeWanted = true
                self.halt()
            }
        })

        observers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                trace("foreground: wanted=\(self.resumeWanted) state=\(self.state) "
                    + "stalled=\(self.isStalled)")
                guard self.resumeWanted else { return }
                self.start(from: self.resumeRoot, client: client)
            }
        })
    }

    private func beginBackgroundGrace() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "keo.indexing") {
            Task { @MainActor [weak self] in self?.halt() }
        }
    }

    private func endBackgroundGrace() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    #if DEBUG
    /// Lets a harness render the running state without a box to talk to.
    func seed(_ progress: Progress) { state = .running(progress) }
    #endif
}
