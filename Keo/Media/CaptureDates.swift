import Foundation
import SwiftUI

/// Remembers the capture date of every file it has ever looked at, so a folder is only
/// analysed once and is correctly ordered the moment you open it again.
///
/// A recorded `nil` means "looked, found nothing" — without that distinction every visit would
/// rescan the same dateless files forever.
actor CaptureDateIndex {
    static let shared = CaptureDateIndex()

    private var records: [String: Double?] = [:]
    private var dirty = false
    private let file: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("capture-dates.json")

        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: Double?].self, from: data) {
            records = stored
        }
    }

    /// Keyed on size too: a file replaced at the same path is a different photo.
    nonisolated static func key(for item: Item) -> String { "\(item.path)|\(item.size)" }

    func known(_ items: [Item]) -> [Item.ID: Date] {
        var found: [Item.ID: Date] = [:]
        for item in items {
            if let stamp = records[Self.key(for: item)] ?? nil {
                found[item.id] = Date(timeIntervalSince1970: stamp)
            }
        }
        return found
    }

    func needsScan(_ items: [Item]) -> [Item] {
        items.filter { records[Self.key(for: $0)] == nil }
    }

    func record(_ date: Date?, for item: Item) {
        records[Self.key(for: item)] = date?.timeIntervalSince1970
        dirty = true
    }

    func save() {
        guard dirty, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: file, options: .atomic)
        dirty = false
    }
}

/// Walks a folder reading only the first few kilobytes of each file, which is all an EXIF or
/// HEIF date needs. Reordering happens once at the end rather than under the user's finger.
@MainActor
final class DateScan: ObservableObject {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    @Published private(set) var progress: Progress?

    private var task: Task<Void, Never>?

    /// Enough for the metadata of every format tested, and cheap enough to do thousands of times.
    private static let prefixBytes = 4 << 10
    /// Deliberately below the thumbnail pipeline's share: the user is looking at the grid,
    /// not at the scan. Background work yields, and its results are persisted anyway.
    private static let parallel = 3
    private static let progressStride = 50

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    /// `onFinished` receives every date discovered during the pass.
    func start(_ media: [Item], client: FreeboxClient,
               onFinished: @escaping ([Item.ID: Date]) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            let pending = await CaptureDateIndex.shared.needsScan(media)
            guard !pending.isEmpty, let self else { return }

            self.progress = Progress(done: 0, total: pending.count)
            var found: [Item.ID: Date] = [:]
            var done = 0

            await withTaskGroup(of: (Item, Date?).self) { group in
                var next = 0
                func feed() {
                    guard next < pending.count else { return }
                    let item = pending[next]
                    next += 1
                    group.addTask {
                        let prefix = try? await client.bytes(item.path, prefix: Self.prefixBytes)
                        return (item, prefix.flatMap(ImageDecoding.captureDate(prefix:)))
                    }
                }
                for _ in 0..<min(Self.parallel, pending.count) { feed() }

                while let (item, date) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    await CaptureDateIndex.shared.record(date, for: item)
                    if let date { found[item.id] = date }
                    done += 1
                    // Publishing every file would invalidate the grid 20 000 times.
                    if done % Self.progressStride == 0 || done == pending.count {
                        self.progress = Progress(done: done, total: pending.count)
                    }
                    feed()
                }
            }

            await CaptureDateIndex.shared.save()
            self.progress = nil
            self.task = nil
            guard !Task.isCancelled else { return }
            onFinished(found)
        }
    }
}

/// Quiet progress while the folder is being analysed — the grid stays usable throughout.
struct DateScanChip: View {
    let progress: DateScan.Progress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Analyse des dates \(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
