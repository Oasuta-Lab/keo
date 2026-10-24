import Foundation
import SwiftUI
import UIKit

/// The one place that reads capture dates off the NAS.
///
/// There used to be two: a per-folder scan and a background walk, which could work the same
/// folder at once and double the traffic to the box. This is a single serial worker with a
/// queue the open folder jumps to the front of.
@MainActor
final class Indexer: ObservableObject {
    struct Progress: Equatable {
        var folder = "/"
        var foldersVisited = 0
        var foldersSkipped = 0
        var mediaFound = 0
        var datesRead = 0
        var adopted = 0
        var unreadable = 0
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
        case finished(Progress)

        var progress: Progress? {
            switch self {
            case .idle: return nil
            case .running(let p), .finished(let p): return p
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var resolution: Resolution?
    @Published var failure: String?

    @AppStorage("lastIndexedAt") private var lastIndexedAt: Double = 0

    /// Deliberately below the thumbnail pipeline's share: the user is looking at the grid.
    private static let parallel = 3
    private static let prefixBytes = 4 << 10
    private static let publishEvery = 20
    /// Backstop against a symlink loop turning this into an infinite walk.
    private static let folderLimit = 5_000

    private enum Job {
        case walk(root: String, client: FreeboxClient, restart: Bool)
        case folder(path: String, items: [Item], client: FreeboxClient)
    }

    private var queue: [Job] = []
    private var runner: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var resumeOnReturn: (root: String, client: FreeboxClient)?
    private var background: UIBackgroundTaskIdentifier = .invalid

    var lastRun: Date? {
        lastIndexedAt > 0 ? Date(timeIntervalSince1970: lastIndexedAt) : nil
    }

    // MARK: Entry points

    func start(from root: String = FreeboxClient.rootPath, client: FreeboxClient,
               restart: Bool = false) {
        queue.append(.walk(root: root, client: client, restart: restart))
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
        resumeOnReturn = nil
        queue.removeAll()
        halt()
    }

    // MARK: Running

    private func pump() {
        guard runner == nil, !queue.isEmpty else { return }
        beginBackgroundGrace()

        runner = Task { [weak self] in
            while let job = await self?.nextJob() {
                switch job {
                case .walk(let root, let client, let restart):
                    await self?.walk(root: root, client: client, restart: restart)
                case .folder(let path, let items, let client):
                    await self?.scanOne(path: path, items: items, client: client)
                }
                if Task.isCancelled { break }
            }
            await self?.finishRun()
        }
    }

    private func nextJob() -> Job? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func finishRun() {
        runner = nil
        await_checkpoint()
        endBackgroundGrace()
        if case .running(let progress) = state { state = .finished(progress) }
    }

    private func await_checkpoint() {
        Task { await IndexStore.shared.checkpoint() }
    }

    private func halt() {
        runner?.cancel()
        runner = nil
        endBackgroundGrace()
        if case .running(let progress) = state { state = .finished(progress) }
    }

    // MARK: Jobs

    private func walk(root: String, client: FreeboxClient, restart: Bool) async {
        var progress = state.progress ?? Progress()
        progress.folder = root
        state = .running(progress)

        do {
            if restart { try await IndexStore.shared.forgetWalk() }
            let generation = try await IndexStore.shared.beginGeneration()

            var pending: [(path: String, modified: Date?, childCount: Int?)] =
                [(root, nil, nil)]
            var visited = 0

            while !pending.isEmpty, !Task.isCancelled, visited < Self.folderLimit {
                let folder = pending.removeFirst()
                visited += 1

                // Untouched since it was fully read: not even listed. This is what makes a
                // second pass cheap.
                if try await IndexStore.shared.isUnchanged(folder.path,
                                                           modified: folder.modified,
                                                           childCount: folder.childCount) {
                    try await IndexStore.shared.touchSubtree(folder.path, generation: generation)
                    progress.foldersSkipped += 1
                    state = .running(progress)
                    continue
                }

                progress.folder = folder.path
                progress.folderDone = 0
                progress.folderTotal = 0
                state = .running(progress)

                guard let contents = try? await client.list(folder.path, order: .name) else {
                    continue
                }
                pending.append(contentsOf: contents.folders.map {
                    ($0.path, $0.modified, $0.childCount)
                })
                progress.foldersVisited += 1
                progress.mediaFound += contents.media.count

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
                await index(contents.media, in: folder.path, generation: generation,
                            stamp: completion, client: client, progress: &progress)
            }

            // Only a pass that ran to the end may decide what has disappeared.
            if !Task.isCancelled, visited < Self.folderLimit {
                try await IndexStore.shared.sweepFolders(generation: generation)
                lastIndexedAt = Date().timeIntervalSince1970
            }
            progress.indexedOverall = (try? await IndexStore.shared.fileCount()) ?? 0
            state = .running(progress)
        } catch {
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
    private func index(_ media: [Item], in folder: String, generation: Int64,
                       stamp: FolderStamp.Completion?,
                       client: FreeboxClient, progress: inout Progress) async {
        guard let store = try? await IndexStore.shared.unread(media, in: folder) else { return }
        var todo = store
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
                    present: stamping ? media : [], sweep: stamping
                )
                batch.removeAll(keepingCapacity: true)
            } catch {
                failure = error.localizedDescription
            }
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
                            let prefix = try await client.bytes(item.path, prefix: Self.prefixBytes)
                            return (item, .success(ImageDecoding.captureDate(prefix: prefix)))
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
                        if let capture { discovered[item.id] = capture }
                        progress.datesRead += 1
                    case .failure:
                        // Left unknown on purpose: a dropped connection must be retried, never
                        // recorded as "this photo has no date".
                        failures += 1
                        progress.unreadable += 1
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
        progress.indexedOverall = (try? await IndexStore.shared.fileCount()) ?? progress.indexedOverall
        state = .running(progress)

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
            Task { @MainActor in
                guard let self, self.state.isRunning else { return }
                self.resumeOnReturn = (root, client)
                self.halt()
                await IndexStore.shared.checkpoint()
            }
        })

        observers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let resume = self.resumeOnReturn else { return }
                self.resumeOnReturn = nil
                self.start(from: resume.root, client: resume.client)
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
