import Foundation
import SwiftUI

/// Walks the whole NAS once, reading each photo's capture date, so browsing never has to.
///
/// The per-folder scan only knows about the folder you are looking at, and loses its place
/// when you leave. This runs from the root, keeps going while you browse, survives navigation,
/// and persists as it goes — stopping and restarting costs only the files not yet read.
@MainActor
final class Indexer: ObservableObject {
    struct Progress: Equatable {
        var folder: String = "/"
        var foldersVisited = 0
        var mediaFound = 0
        var datesRead = 0
        var alreadyKnown = 0

        var pending: Int { max(mediaFound - datesRead - alreadyKnown, 0) }
        var fraction: Double {
            let handled = Double(datesRead + alreadyKnown)
            return mediaFound == 0 ? 0 : min(handled / Double(mediaFound), 1)
        }
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
    @AppStorage("lastIndexedAt") private var lastIndexedAt: Double = 0

    private var task: Task<Void, Never>?

    /// Same restraint as the per-folder scan: the grid matters more than the index.
    private static let parallel = 3
    private static let prefixBytes = 4 << 10

    var lastRun: Date? {
        lastIndexedAt > 0 ? Date(timeIntervalSince1970: lastIndexedAt) : nil
    }

    func stop() {
        task?.cancel()
        task = nil
        if case .running(let progress) = state { state = .finished(progress) }
    }

    func start(from root: String = FreeboxClient.rootPath, client: FreeboxClient) {
        guard !state.isRunning else { return }
        task = Task { [weak self] in
            await self?.run(root: root, client: client)
        }
    }

    private func run(root: String, client: FreeboxClient) async {
        var progress = Progress(folder: root)
        state = .running(progress)

        var queue = [root]
        var guardCount = 0

        while !queue.isEmpty, !Task.isCancelled, guardCount < Self.folderLimit {
            let path = queue.removeFirst()
            guardCount += 1

            progress.folder = path
            progress.foldersVisited += 1
            state = .running(progress)

            guard let contents = try? await client.list(path, order: .name) else { continue }
            queue.append(contentsOf: contents.folders.map(\.path))

            progress.mediaFound += contents.media.count
            let known = await CaptureDateIndex.shared.known(contents.media)
            let pending = await CaptureDateIndex.shared.needsScan(contents.media)
            progress.alreadyKnown += known.count
            state = .running(progress)

            await read(pending, client: client, progress: &progress)
            await CaptureDateIndex.shared.save()
        }

        await CaptureDateIndex.shared.save()
        if !Task.isCancelled { lastIndexedAt = Date().timeIntervalSince1970 }
        state = .finished(progress)
        task = nil
    }

    private func read(_ items: [Item], client: FreeboxClient,
                      progress: inout Progress) async {
        guard !items.isEmpty else { return }
        var done = 0

        await withTaskGroup(of: (Item, Date?).self) { group in
            var next = 0
            func feed() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    let prefix = try? await client.bytes(item.path, prefix: Self.prefixBytes)
                    return (item, prefix.flatMap(ImageDecoding.captureDate(prefix:)))
                }
            }
            for _ in 0..<min(Self.parallel, items.count) { feed() }

            while let (item, date) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                await CaptureDateIndex.shared.record(date, for: item)
                done += 1
                if done % 25 == 0 {
                    progress.datesRead += 25
                    state = .running(progress)
                }
                feed()
            }
        }

        progress.datesRead += done % 25
        state = .running(progress)
    }

    /// Backstop against a symlink loop turning this into an infinite walk.
    private static let folderLimit = 5_000
}
