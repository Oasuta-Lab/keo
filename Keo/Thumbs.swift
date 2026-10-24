import AVFoundation
import CryptoKit
import ImageIO
import UIKit

/// Thumbnails, cheap. Tries the file's embedded preview from a 256 KB range request first;
/// only falls back to a full download when the format hides no preview up front.
actor ThumbCache {
    static let shared = ThumbCache()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // ponytail: full download capped at 40 MB — a RAW with no embedded preview just shows a placeholder.
    private let fullDownloadLimit: Int64 = 40 << 20
    private let probeBytes = 256 << 10

    func thumbnail(for item: Item, client: FreeboxClient, maxPixel: CGFloat = 400) async -> UIImage? {
        guard item.kind == .image || item.kind == .video else { return nil }

        let key = Self.key(for: item, maxPixel: maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        let produced = item.kind == .video
            ? await frame(item, client: client, maxPixel: maxPixel)
            : await render(item, client: client, maxPixel: maxPixel)
        guard let image = produced else { return nil }
        memory.setObject(image, forKey: key as NSString)
        try? image.jpegData(compressionQuality: 0.8)?.write(to: file, options: .atomic)
        return image
    }

    private func render(_ item: Item, client: FreeboxClient, maxPixel: CGFloat) async -> UIImage? {
        if let probe = try? await client.data(item.path, firstBytes: probeBytes),
           let image = Self.embeddedThumbnail(probe, maxPixel: maxPixel) {
            return image
        }
        guard item.size <= fullDownloadLimit,
              let data = try? await client.data(item.path) else { return nil }
        return Self.downsample(data, maxPixel: maxPixel)
    }

    /// AVFoundation range-requests only the atoms it needs, so this never pulls the whole video.
    private func frame(_ item: Item, client: FreeboxClient, maxPixel: CGFloat) async -> UIImage? {
        guard let source = try? await client.videoAsset(item.path) else { return nil }

        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // A second in, to skip a black leader; falls back to the very first frame for short clips.
        for seconds in [1.0, 0.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: time) {
                withExtendedLifetime(source) {}   // the resource loader must outlive the request
                return UIImage(cgImage: cgImage)
            }
        }
        return nil
    }

    /// Only returns the preview already baked into the file — never decodes the full image,
    /// so a partial download is enough.
    private static func embeddedThumbnail(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cgImage.width > 32 else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func key(for item: Item, maxPixel: CGFloat) -> String {
        let seed = "\(item.path)|\(item.size)|\(Int(maxPixel))"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
