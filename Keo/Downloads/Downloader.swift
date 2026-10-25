import Photos
import SwiftUI

@MainActor
final class Downloader: ObservableObject {
    enum Destination { case photos, share }

    struct SharePayload: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    @Published private(set) var job: DownloadJob?
    @Published var share: SharePayload?
    @Published var error: String?

    private var task: Task<Void, Never>?

    var isRunning: Bool { job != nil }

    func save(_ items: [Item], from client: FreeboxClient, to destination: Destination) {
        guard !items.isEmpty, task == nil else { return }
        task = Task { await run(items, client: client, destination: destination) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ items: [Item], client: FreeboxClient, destination: Destination) async {
        defer {
            job = nil
            task = nil
        }

        if destination == .photos {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                error = "Keo n'a pas l'autorisation d'ajouter des photos. "
                      + "Réglages → Keo → Photos → Ajouter uniquement."
                return
            }
        }

        job = DownloadJob(total: items.count, completed: 0, currentName: "", currentFraction: 0)
        var downloaded: [URL] = []

        for item in items {
            if Task.isCancelled { break }
            job?.currentName = item.name
            job?.currentFraction = 0

            do {
                let file = try await client.download(item.path) { [weak self] fraction in
                    Task { @MainActor in self?.job?.currentFraction = fraction }
                }
                switch destination {
                case .photos:
                    try await Self.addToPhotos(file, named: item.name,
                                               isVideo: item.kind == .video)
                case .share: downloaded.append(file)
                }
            } catch is CancellationError {
                break
            } catch {
                self.error = "\(item.name) : \(error.localizedDescription)"
                break
            }

            job?.completed += 1
        }

        if destination == .share, !downloaded.isEmpty, !Task.isCancelled {
            share = SharePayload(urls: downloaded)
        }
    }

    /// `nonisolated` and `static`, and that is the whole point.
    ///
    /// `performChanges` runs its block on `com.apple.PHPhotoLibrary.transaction.high`. As an
    /// instance method of this `@MainActor` class, the block inherited main-actor isolation,
    /// so Swift 6 inserted an isolation check that trapped the moment Photos called it —
    /// `dispatch_assert_queue_fail`, every single save. Nothing crosses in but `Sendable`
    /// values, so there is nothing for the actor to protect here.
    nonisolated private static func addToPhotos(_ file: URL, named name: String,
                                                isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = name
            request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: options)
        }
    }
}

// MARK: - Views

struct DownloadBar: View {
    @ObservedObject var downloader: Downloader

    var body: some View {
        if let job = downloader.job {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text(job.currentName)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(job.position) / \(job.total)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    // "Arrêter" and not "Annuler": the undo banner can be on screen at the same
                    // time, and two buttons reading "Annuler" with opposite meanings is
                    // a trap. Stopping a download is also what this actually does.
                    Button("Arrêter") { downloader.cancel() }
                        .font(.footnote)
                }
                ProgressView(value: job.fraction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // A card in the same floating family as the action bar, not a slab glued
            // underneath it.
            .background(.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
