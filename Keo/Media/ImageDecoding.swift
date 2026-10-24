import ImageIO
import UIKit

enum ImageDecoding {
    /// Returns only the preview already baked into the file. It never decodes the full image,
    /// which is what makes a 256 KB range request enough to fill a grid cell.
    static func embeddedPreview(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        return thumbnail(from: source, maxPixel: maxPixel, decodeFullImage: false)
    }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return thumbnail(from: source, maxPixel: maxPixel, decodeFullImage: true)
    }

    /// Decodes straight off disk, so a 50 MP original never exists as a `Data` in memory.
    static func downsample(fileAt url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return thumbnail(from: source, maxPixel: maxPixel, decodeFullImage: true)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat,
                                  decodeFullImage: Bool) -> UIImage? {
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if decodeFullImage {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 16 else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// Computed rather than stored: a `CFDictionary` is not `Sendable`, so a shared static
    /// would be a mutable global as far as the compiler is concerned.
    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }
}

extension UIImage {
    /// Decoded footprint, used as the memory cache's cost so the budget is in bytes rather
    /// than in a count that says nothing about actual pressure.
    var decodedByteCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
