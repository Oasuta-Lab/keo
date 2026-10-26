import CoreGraphics
// For `pathExtension`: the same one `Item.classify` uses, so the two agree on what a
// file's extension is.
import Foundation

/// Decides whether a file's *embedded* preview is good enough to put in a grid cell.
///
/// Two ways it is not, both seen on real files:
/// a 6016×6016 JPEG whose EXIF thumbnail is 160×160 — stretched across the cell it reads as
/// blurry — and previews whose shape does not match the photo, which crop or letterbox the
/// subject. Rejecting sends the file down the slower full-decode path, which is cached
/// afterwards, so the cost is paid once.
enum PreviewPolicy {
    /// Below this fraction of the requested size, upscaling is visible.
    static let minimumScale: CGFloat = 0.75

    /// Aspect ratios rarely match to the pixel; 2% absorbs rounding without letting a
    /// genuinely different crop through.
    static let maximumAspectDrift: CGFloat = 0.02

    /// Whether the 256 KB probe can be believed at all for this file.
    ///
    /// ImageIO builds a thumbnail out of a *truncated* file without being asked to, and
    /// without saying so. Measured on a 762 KB PNG cut at 256 KB: it returns an image of the
    /// right pixel size and the right aspect ratio, **100 % transparent**. `accepts` only
    /// judges size and ratio, so it took it — the cell cached a blank and the full-download
    /// fallback, which would have worked, never ran. That is the bug behind "some PNGs have
    /// no preview".
    ///
    /// Two cases are safe. A format that carries a real preview ahead of its pixel data: JPEG
    /// and HEIC write an EXIF thumbnail, and every raw format embeds a full JPEG. And a file
    /// small enough that the probe is the whole file, where there is nothing to truncate.
    ///
    /// PNG, GIF, BMP and WebP carry nothing of the sort, so for them the probe is only worth
    /// the capture date it reads on the way past.
    static func trustsProbe(path: String, size: Int64, probeBytes: Int) -> Bool {
        if size <= Int64(probeBytes) { return true }
        return previewBearing.contains((path as NSString).pathExtension.lowercased())
    }

    /// Formats that put a decodable preview before the image data.
    private static let previewBearing: Set<String> =
        ["jpg", "jpeg", "heic", "heif", "tif", "tiff",
         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

    static func accepts(preview: CGSize, fullImage: CGSize?, requested: CGFloat) -> Bool {
        guard preview.width > 0, preview.height > 0 else { return false }
        guard max(preview.width, preview.height) >= requested * minimumScale else { return false }

        guard let fullImage, fullImage.width > 0, fullImage.height > 0 else {
            return true   // nothing to compare against; size alone has to do
        }
        return drift(preview, fullImage) <= maximumAspectDrift
    }

    static func drift(_ preview: CGSize, _ fullImage: CGSize) -> CGFloat {
        let previewRatio = preview.width / preview.height
        let fullRatio = fullImage.width / fullImage.height
        return abs(previewRatio - fullRatio) / fullRatio
    }

    /// EXIF orientations 5 to 8 are the quarter turns: the declared pixel size is pre-rotation,
    /// while the extracted preview has already been transformed.
    static func oriented(_ size: CGSize, exifOrientation: Int?) -> CGSize {
        guard let exifOrientation, (5...8).contains(exifOrientation) else { return size }
        return CGSize(width: size.height, height: size.width)
    }
}
