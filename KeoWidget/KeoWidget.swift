import ImageIO
import SwiftUI
import WidgetKit

/// The entry point. A `@main WidgetBundle` is what WidgetKit looks for, which is why the
/// Info.plist deliberately carries no `NSExtensionPrincipalClass`.
@main
struct KeoWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeoWidget()
    }
}

struct KeoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeoWidget", provider: Provider()) { entry in
            KeoWidgetView(entry: entry)
        }
        .configurationDisplayName("Keo")
        .description("Les photos de vos dossiers épinglés.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // A photo has nothing to gain from a margin of wallpaper around it.
        .contentMarginsDisabled()
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    /// A file, never a bitmap. A timeline is archived whole, and 48 decoded photos in one is
    /// exactly how a 30 MB extension gets killed.
    let file: URL?
    /// The widget's own size in points; the view turns it into pixels with its scale.
    let size: CGSize
    /// Set instead of `file` when there is nothing to show, and why.
    let message: String?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), file: nil, size: context.displaySize, message: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(entries(in: context).first
                   ?? Entry(date: Date(), file: nil, size: context.displaySize,
                            message: WidgetStore.emptyMessage()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: entries(in: context), policy: .atEnd))
    }

    /// 48 entries, one every 30 minutes, covering a day — so one background reload per day
    /// against a budget of roughly 40 to 70. The app's `reloadAllTimelines()` from the
    /// foreground is not budgeted at all, which is what actually keeps this fresh.
    private func entries(in context: Context) -> [Entry] {
        let folder = WidgetStore.manifest()?.folders.first
        guard let folder, let home = WidgetStore.home(for: folder) else {
            return [Entry(date: Date(), file: nil, size: context.displaySize,
                          message: WidgetStore.emptyMessage())]
        }
        return WidgetStore.schedule(folder.images, in: home, size: context.displaySize)
    }
}

// MARK: - Reading the container

enum WidgetStore {
    static func manifest() -> WidgetManifest? {
        guard let directory = WidgetManifest.directory,
              let data = try? Data(contentsOf: directory
                  .appendingPathComponent(WidgetManifest.fileName)),
              let manifest = try? JSONDecoder().decode(WidgetManifest.self, from: data),
              // A widget left behind by an older build refuses rather than guesses.
              manifest.version == WidgetManifest.currentVersion else { return nil }
        return manifest
    }

    static func home(for folder: WidgetManifest.Folder) -> URL? {
        WidgetManifest.directory?.appendingPathComponent(WidgetManifest.key(for: folder.path),
                                                         isDirectory: true)
    }

    /// Distinguishes "the app has never run" from "nothing is pinned": the second has a
    /// one-gesture answer, and saying so is the whole point of the message.
    static func emptyMessage() -> String {
        guard let manifest = manifest() else { return "Ouvre Keo pour remplir le widget" }
        return manifest.folders.isEmpty ? "Épingle un dossier dans Keo"
                                        : "Ouvre Keo pour remplir le widget"
    }

    static func schedule(_ images: [String], in home: URL, size: CGSize) -> [Entry] {
        // The manifest only ever names flat hex, but it is read from a file: a name that
        // could climb out of the container must not be joined onto it.
        let files = images
            .filter { !$0.contains("/") && !$0.contains("..") && !$0.isEmpty }
            .map { home.appendingPathComponent($0) }
        guard !files.isEmpty else {
            return [Entry(date: Date(), file: nil, size: size, message: emptyMessage())]
        }

        let start = Date()
        return (0..<48).map { step in
            Entry(date: start.addingTimeInterval(TimeInterval(step) * 1_800),
                  file: files[step % files.count], size: size, message: nil)
        }
    }
}

// MARK: - Rendering

struct KeoWidgetView: View {
    let entry: Entry

    @Environment(\.displayScale) private var scale

    var body: some View {
        content
            .containerBackground(.black, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if let file = entry.file,
           let image = downsample(file, maxPixel: max(entry.size.width, entry.size.height) * scale) {
            Image(decorative: image, scale: 1)
                .resizable()
                // The Home Screen's tinted mode flattens a photo to a white silhouette,
                // which for a photo widget is a bug rather than a style. Order is forced:
                // it takes an `Image` and gives back a `View`, so it sits between the two.
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
                .clipped()
        } else {
            Text(entry.message ?? "Ouvre Keo pour remplir le widget")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    /// Copied from `Keo/Media/ImageDecoding.swift` rather than shared. Sharing would mean
    /// moving that file out of the app's synchronized group and editing the project, the
    /// check command, the README structure table and the read-only scan — a far larger blast
    /// radius than a dozen duplicated lines.
    private func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard maxPixel > 0,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
