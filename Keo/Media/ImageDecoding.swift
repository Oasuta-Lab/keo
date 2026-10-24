import ImageIO
import UIKit

enum ImageDecoding {
    /// Returns the preview already baked into the file, but only when it is actually usable.
    /// It never decodes the full image, which is what makes a 256 KB range request enough.
    /// `nil` means "not good enough" as much as "not there" — the caller falls back.
    static func embeddedPreview(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)

        guard let preview = thumbnail(from: source, maxPixel: maxPixel, decodeFullImage: false),
              PreviewPolicy.accepts(preview: preview.size,
                                    fullImage: declaredSize(of: source),
                                    requested: maxPixel) else {
            return nil
        }
        return preview
    }

    /// The photo's real pixel size, read from the metadata rather than decoded.
    private static func declaredSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else {
            return nil
        }
        return PreviewPolicy.oriented(CGSize(width: width, height: height),
                                      exifOrientation: properties[kCGImagePropertyOrientation] as? Int)
    }

    /// JPEG has no alpha: a transparent PNG round-tripped through it comes back pure white,
    /// which is what those blank grid cells were.
    static func cacheData(for image: UIImage) -> Data? {
        image.hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.8)
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
    var hasAlpha: Bool {
        guard let info = cgImage?.alphaInfo else { return false }
        return info != .none && info != .noneSkipFirst && info != .noneSkipLast
    }

    /// Decoded footprint, used as the memory cache's cost so the budget is in bytes rather
    /// than in a count that says nothing about actual pressure.
    var decodedByteCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
