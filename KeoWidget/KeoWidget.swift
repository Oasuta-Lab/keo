import AppIntents
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
        AppIntentConfiguration(kind: "KeoWidget", intent: SelectFolder.self,
                               provider: Provider()) { entry in
            KeoWidgetView(entry: entry)
        }
        .configurationDisplayName("Keo")
        .description("Les photos d'un dossier épinglé.")
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

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), file: nil, size: context.displaySize, message: nil)
    }

    func snapshot(for configuration: SelectFolder, in context: Context) async -> Entry {
        entries(for: configuration, in: context)[0]
    }

    /// 48 entries, one every 30 minutes, covering a day — so one background reload per day
    /// against a budget of roughly 40 to 70. The app's `reloadAllTimelines()` from the
    /// foreground is not budgeted at all, and is what actually keeps this fresh.
    func timeline(for configuration: SelectFolder, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: entries(for: configuration, in: context), policy: .atEnd)
    }

    private func entries(for configuration: SelectFolder, in context: Context) -> [Entry] {
        let size = context.displaySize

        guard let manifest = WidgetStore.manifest() else {
            return [WidgetStore.blank(size, "Ouvre Keo pour remplir le widget")]
        }
        guard !manifest.folders.isEmpty else {
            return [WidgetStore.blank(size, "Épingle un dossier dans Keo")]
        }
        // Never configured — a widget dropped straight onto the Home Screen still has to
        // show something rather than wait for someone to open its edit sheet.
        guard let chosen = configuration.folder?.id else {
            return WidgetStore.schedule(manifest.folders[0], size: size)
        }
        guard let folder = manifest.folders.first(where: { $0.path == chosen }) else {
            // Unpinned since. Showing another folder's photos under the chosen folder's
            // name would be worse than saying nothing.
            return [WidgetStore.blank(size, "Ce dossier n'est plus épinglé")]
        }
        return WidgetStore.schedule(folder, size: size)
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

    static func blank(_ size: CGSize, _ message: String) -> Entry {
        Entry(date: Date(), file: nil, size: size, message: message)
    }

    static func schedule(_ folder: WidgetManifest.Folder, size: CGSize) -> [Entry] {
        guard let directory = WidgetManifest.directory else {
            return [blank(size, "Ouvre Keo pour remplir le widget")]
        }
        let home = directory.appendingPathComponent(WidgetManifest.key(for: folder.path),
                                                    isDirectory: true)
        // The manifest only ever names flat hex, but it is read from a file: a name that
        // could climb out of the container must not be joined onto it.
        let files = folder.images
            .filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }
            .map { home.appendingPathComponent($0) }
        guard !files.isEmpty else { return [blank(size, "Ouvre Keo pour remplir le widget")] }

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
