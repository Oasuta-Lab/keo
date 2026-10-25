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
        OnThisDayWidget()
        ShortcutsWidget()
        CoverageWidget()
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

struct Entry: TimelineEntry, Sendable {
    let date: Date
    /// File names, never bitmaps. WidgetKit archives a timeline whole, and every archived
    /// entry keeps hold of whatever its view decoded — see `WidgetStore.steps`.
    let files: [URL]
    let name: String
    let path: String
    /// Both optional in the manifest and both carried through as such: a folder the index has
    /// not finished genuinely has no count, and `0` would read as "this folder is empty".
    let mediaCount: Int?
    let span: String?
    /// The widget's own size in points; the view turns it into pixels with its scale.
    let size: CGSize
    /// Set instead of `files` when there is nothing to show, and why.
    let message: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        WidgetStore.blank(context.displaySize, nil)
    }

    func snapshot(for configuration: SelectFolder, in context: Context) async -> Entry {
        entries(for: configuration, in: context)[0]
    }

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
    /// Four entries six hours apart — a day of coverage for one background reload, the same
    /// budget the previous forty-eight half-hourly entries bought.
    ///
    /// The count is a memory decision, not a freshness one. WidgetKit renders and archives
    /// every entry of a timeline in one pass inside the extension, and each archived entry
    /// retains the photo its view decoded. Covering a large widget costs about 5 MB of pixels
    /// whatever way it is cut, so forty-eight entries asked a 30 MB extension for well over a
    /// hundred — it was killed before drawing anything, which is the black empty widget the
    /// owner reported, and why only the small family (a quarter of the pixels) survived.
    /// Four entries put the worst case near 19 MB. Freshness never depended on the count
    /// anyway: `reloadAllTimelines()` from the app in the foreground is what drives it, and
    /// it is not budgeted at all.
    static let steps = 4
    static let stride: TimeInterval = 21_600

    /// « il y a 7 ans », derived from the year rather than stored with it: the manifest is
    /// rewritten hourly but a widget archived on 31 December would otherwise still say in
    /// January what it said the year before.
    static func ago(_ year: Int, now: Date) -> String {
        switch Calendar.current.component(.year, from: now) - year {
        case ..<1: return "cette année"
        case 1: return "il y a 1 an"
        case let years: return "il y a \(years) ans"
        }
    }

    static func manifest() -> WidgetManifest? {
        guard let directory = WidgetManifest.directory,
              let data = try? Data(contentsOf: directory
                  .appendingPathComponent(WidgetManifest.fileName)),
              let manifest = try? JSONDecoder().decode(WidgetManifest.self, from: data),
              // A widget left behind by an older build refuses rather than guesses.
              manifest.version == WidgetManifest.currentVersion else { return nil }
        return manifest
    }

    static func blank(_ size: CGSize, _ message: String?) -> Entry {
        Entry(date: Date(), files: [], name: "", path: "", mediaCount: nil, span: nil,
              size: size, message: message)
    }

    /// The rendered files of one folder, newest capture first, as absolute URLs.
    static func files(of folder: WidgetManifest.Folder) -> [URL] {
        guard let directory = WidgetManifest.directory else { return [] }
        let home = directory.appendingPathComponent(WidgetManifest.key(for: folder.path),
                                                    isDirectory: true)
        // The manifest only ever names flat hex, but it is read from a file: a name that
        // could climb out of the container must not be joined onto it.
        return folder.images
            .filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }
            .map { home.appendingPathComponent($0) }
    }

    static func schedule(_ folder: WidgetManifest.Folder, size: CGSize) -> [Entry] {
        let files = files(of: folder)
        guard !files.isEmpty else {
            return [blank(size, "Ouvre Keo pour remplir le widget")]
        }

        let start = Date()
        return (0..<steps).map { step in
            // Rotating rather than indexing means the large family's mosaic turns over too,
            // instead of changing only its first cell.
            let offset = (step * 4) % files.count
            return Entry(date: start.addingTimeInterval(TimeInterval(step) * stride),
                         files: Array(files[offset...] + files[..<offset]),
                         name: folder.name, path: folder.path,
                         mediaCount: folder.mediaCount, span: folder.span,
                         size: size, message: nil)
        }
    }
}

// MARK: - Rendering

/// A photo sized to the box it is given rather than to its own proportions.
///
/// `scaledToFill()` hands back a frame that *exceeds* the proposal on one axis, so a
/// `.clipped()` applied to the image clips against that oversized frame and does nothing.
///
/// At the root of a widget that is harmless — the host centres and crops the overflow, and a
/// render of the three families showed all of them covered at 100 %. Inside a **stack** it is
/// not: an oversized cell is measured at its full width and takes the room from its
/// neighbours. A three-cell strip rendered 15 / 70 / 15 instead of 33 / 33 / 33. A zero-size
/// container settles the frame first, and the overlay is clipped to it.
struct Photo: View {
    let file: URL?
    /// The long edge of the box, in points. Sizing each decode to its own cell rather than to
    /// the whole widget is what keeps a mosaic inside the extension's budget.
    let side: CGFloat

    @Environment(\.displayScale) private var scale

    var body: some View {
        Color.clear
            .overlay {
                if let file, let image = Self.downsample(file, maxPixel: side * scale) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        // The Home Screen's tinted mode flattens a photo to a white
                        // silhouette, which for a photo widget is a bug rather than a style.
                        // Order is forced: it takes an `Image` and gives back a `View`, so it
                        // sits between the two.
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                }
            }
            .clipped()
    }

    /// Copied from `Keo/Media/ImageDecoding.swift` rather than shared. Sharing would mean
    /// moving that file out of the app's synchronized group and editing the project, the
    /// check command, the README structure table and the read-only scan — a far larger blast
    /// radius than a dozen duplicated lines.
    static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
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

/// The folder's name over the bottom of a photo.
///
/// A photo can be bright anywhere, so the text gets its own ground rather than a shadow that
/// would vanish over a white sky.
struct Caption: View {
    let name: String
    /// Nil when there is nothing true to add — never a guess, and never a zero.
    let detail: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(compact ? .caption : .subheadline)
                .fontWeight(.semibold)
                .lineLimit(compact ? 2 : 1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

/// Several photos of the folder at once, for the large family.
///
/// A hero with a strip under it rather than a fixed grid, because the strip simply gets
/// shorter when the folder offers fewer photos: four cells, then three, then two, then the
/// hero alone. A grid would have had to repeat a photo to stay square.
///
/// Worst case on the largest iPhone (364 × 382 pt at 3×): the hero decodes a 1092 px long
/// edge, about 3.6 MB for a 4:3 photo, and three strip cells about 0.4 MB each — 4.8 MB for
/// the entry, 19 MB for the four archived entries of the timeline.
struct Mosaic: View {
    let files: [URL]
    let size: CGSize

    private let gap: CGFloat = 2

    var body: some View {
        let count = min(3, files.count - 1)
        VStack(spacing: gap) {
            Photo(file: files.first, side: size.width)
            if count > 0 {
                let height = size.height * 0.3
                let width = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)
                HStack(spacing: gap) {
                    ForEach(files.dropFirst().prefix(count), id: \.self) { file in
                        Photo(file: file, side: max(width, height))
                    }
                }
                .frame(height: height)
            }
        }
    }
}

struct KeoWidgetView: View {
    let entry: Entry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.black, for: .widget)
            .widgetURL(entry.path.isEmpty ? nil : WidgetManifest.link(folder: entry.path))
    }

    @ViewBuilder
    private var content: some View {
        if entry.files.isEmpty {
            Text(entry.message ?? "Ouvre Keo pour remplir le widget")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            photos
                .overlay(alignment: .bottom) {
                    Caption(name: entry.name, detail: detail, compact: family == .systemSmall)
                }
        }
    }

    @ViewBuilder
    private var photos: some View {
        if family == .systemLarge {
            Mosaic(files: entry.files, size: entry.size)
        } else {
            Photo(file: entry.files.first, side: max(entry.size.width, entry.size.height))
        }
    }

    /// « 14 595 photos · 2009 – 2024 », and only the halves that are true.
    ///
    /// Both sides are optional in the manifest, and both are omitted when absent rather than
    /// guessed: on a folder the index has not finished, the count is genuinely unknown, and
    /// falling back on `files.count` would report the twelve pre-rendered covers as if they
    /// were the folder. Small has no room for any of it.
    private var detail: String? {
        guard family != .systemSmall else { return nil }
        var parts: [String] = []
        if let count = entry.mediaCount {
            parts.append("\(count.formatted()) photo\(count == 1 ? "" : "s")")
        }
        if let span = entry.span { parts.append(span) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
