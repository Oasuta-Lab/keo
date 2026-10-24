import AVFoundation
import UIKit

/// Thumbnails for an arbitrarily large library.
///
/// Four properties matter at scale, and none of them were there before:
/// a memory budget in **bytes** rather than in images, a hard cap on concurrent fetches,
/// coalescing so N cells asking for the same file cause one fetch, and prefetching ahead of
/// the scroll. The ideas are Nuke's; the fetch is ours, because a Keo thumbnail is a 256 KB
/// range request plus an embedded-preview decode, not a plain download.
actor ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    static let gridSize: CGFloat = 400

    private let memory = MemoryCache(byteLimit: 80 << 20)
    private let disk = DiskCache(name: "thumbs", budget: 512 << 20)

    /// One task per key, shared by every caller that wants the same thumbnail.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Separate gates so a prefetch never makes a visible cell wait behind it.
    private let visible = Gate(limit: 4)
    private let ahead = Gate(limit: 2)

    private var trimmed = false

    // ponytail: full download capped at 40 MB — a RAW with no embedded preview stays a placeholder.
    private let fullDownloadLimit: Int64 = 40 << 20
    private let probeBytes = 256 << 10

    // MARK: Entry points

    func thumbnail(for item: Item, client: FreeboxClient,
                   maxPixel: CGFloat = gridSize) async -> UIImage? {
        await trimOnce()
        guard item.isMedia else { return nil }

        let key = DiskCache.key(for: item.path, size: item.size, maxPixel: Int(maxPixel))
        if let cached = memory[key] { return cached }

        return await load(item, client: client, key: key, maxPixel: maxPixel, gate: visible)
    }

    /// Warms the cache for rows the user is about to reach. Fire-and-forget by design: the
    /// result lands in the cache, and the cell picks it up when it appears.
    func prefetch(_ items: [Item], client: FreeboxClient, maxPixel: CGFloat = gridSize) {
        for item in items where item.isMedia {
            let key = DiskCache.key(for: item.path, size: item.size, maxPixel: Int(maxPixel))
            guard memory[key] == nil, inFlight[key] == nil else { continue }

            Task(priority: .utility) {
                _ = await self.load(item, client: client, key: key,
                                    maxPixel: maxPixel, gate: self.ahead)
            }
        }
    }

    // MARK: Loading

    private func load(_ item: Item, client: FreeboxClient, key: String,
                      maxPixel: CGFloat, gate: Gate) async -> UIImage? {
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [disk, memory] in
            if let data = disk.read(key), let image = UIImage(data: data) {
                memory.insert(image, for: key)
                return image
            }

            await gate.wait()
            defer { Task { await gate.signal() } }

            guard let image = await self.produce(item, client: client, maxPixel: maxPixel) else {
                return nil
            }
            memory.insert(image, for: key)
            if let encoded = ImageDecoding.cacheData(for: image) {
                disk.write(encoded, for: key)
            }
            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    private func produce(_ item: Item, client: FreeboxClient, maxPixel: CGFloat) async -> UIImage? {
        switch item.kind {
        case .video: return await frame(item, client: client, maxPixel: maxPixel)
        default: return await still(item, client: client, maxPixel: maxPixel)
        }
    }

    private func still(_ item: Item, client: FreeboxClient, maxPixel: CGFloat) async -> UIImage? {
        if let probe = try? await client.bytes(item.path, prefix: probeBytes) {
            // The prefix is already here, so the capture date costs nothing to read.
            await CaptureDateIndex.shared.record(ImageDecoding.captureDate(prefix: probe), for: item)
            if let image = ImageDecoding.embeddedPreview(probe, maxPixel: maxPixel) {
                return image
            }
        }
        // No embedded preview: fall back to the file itself, streamed to disk rather than
        // held in memory, and deleted as soon as it is decoded.
        guard item.size <= fullDownloadLimit,
              let file = try? await client.download(item.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return ImageDecoding.downsample(fileAt: file, maxPixel: maxPixel)
    }

    /// AVFoundation range-requests only the atoms it needs, so this never pulls the whole video.
    private func frame(_ item: Item, client: FreeboxClient, maxPixel: CGFloat) async -> UIImage? {
        guard let source = try? await client.videoSource(item.path) else { return nil }
        let authenticated = AuthenticatedAsset(source: source)

        let generator = AVAssetImageGenerator(asset: authenticated.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // A second in, to skip a black leader; falls back to the first frame for short clips.
        for seconds in [1.0, 0.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                withExtendedLifetime(authenticated) {}   // the resource loader must outlive this
                return UIImage(cgImage: image)
            }
        }
        return nil
    }

    private func trimOnce() async {
        guard !trimmed else { return }
        trimmed = true
        let disk = self.disk
        Task.detached(priority: .background) { disk.trim() }
    }
}

// MARK: - Memory cache

/// `NSCache` with a budget expressed in bytes. The previous `countLimit = 600` allowed
/// roughly 384 MB of decoded bitmaps, which is what a jetsam looks like.
/// `@unchecked` because `NSCache` is documented as thread-safe but predates `Sendable`;
/// nothing else here is mutable.
private final class MemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init(byteLimit: Int) {
        cache.totalCostLimit = byteLimit
    }

    subscript(key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.decodedByteCost)
    }
}

// MARK: - Concurrency gate

/// A counting semaphore that suspends instead of blocking a thread. Without it, scrolling
/// fast through thousands of cells starts thousands of fetches at once.
private actor Gate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func wait() async {
        guard active >= limit else {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func signal() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
