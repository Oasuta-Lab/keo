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

    /// Same, from a downloaded prefix rather than a whole file. 4 KB is enough for both JPEG
    /// and HEIC — but the source must *not* be the incremental one used for previews: in
    /// non-final incremental mode ImageIO refuses to parse HEIF metadata and returns nothing.
    static func captureDate(prefix: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(prefix as CFData, sourceOptions) else {
            return nil
        }
        return captureDate(in: source)
    }

    /// The date the shutter actually fired, read from the file's metadata. The listing only
    /// carries the file's modification time, which on a NAS is often the day it was copied.
    static func captureDate(fileAt url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return captureDate(in: source)
    }

    private static func captureDate(in source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let stamp = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                 ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
                 ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        return stamp.flatMap(exifFormatter.date(from:))
    }

    /// EXIF stamps look like "2026:10:24 15:03:41", with no timezone — read as local time.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

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
