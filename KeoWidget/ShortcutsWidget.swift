import SwiftUI
import WidgetKit

/// The pinned folders as tiles, each one a door to its own folder.
///
/// `StaticConfiguration`, not `AppIntentConfiguration`: the widget shows the pinned folders,
/// and there is nothing to choose. Small is not offered — a single tile is already the folder
/// widget, and better at it.
struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeoShortcuts", provider: ShortcutsProvider()) { entry in
            ShortcutsView(entry: entry)
        }
        .configurationDisplayName("Épingles Keo")
        .description("Les dossiers épinglés, un appui pour y aller.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Timeline

struct ShortcutsEntry: TimelineEntry, Sendable {
    let date: Date
    let tiles: [Tile]
    let size: CGSize
    let message: String?

    struct Tile: Identifiable, Sendable {
        var id: String { path }
        let path: String
        let name: String
        /// The folder's most recent photo, the one that makes the tile recognisable.
        let cover: URL?
    }
}

struct ShortcutsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutsEntry {
        ShortcutsEntry(date: Date(), tiles: [], size: context.displaySize, message: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShortcutsEntry) -> Void) {
        completion(entry(in: context))
    }

    /// One entry, renewed daily. Unlike the folder widget this one has nothing that rotates:
    /// the tiles are navigation, and a shortcut that moved under the finger between two
    /// glances would be worse than a stale cover. The app's `reloadAllTimelines()` is what
    /// brings a newly pinned folder in.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShortcutsEntry>) -> Void) {
        let next = Date().addingTimeInterval(86_400)
        completion(Timeline(entries: [entry(in: context)], policy: .after(next)))
    }

    private func entry(in context: Context) -> ShortcutsEntry {
        let size = context.displaySize
        guard let manifest = WidgetStore.manifest() else {
            return ShortcutsEntry(date: Date(), tiles: [], size: size,
                                  message: "Ouvre Keo pour remplir le widget")
        }
        guard !manifest.folders.isEmpty else {
            return ShortcutsEntry(date: Date(), tiles: [], size: size,
                                  message: "Épingle un dossier dans Keo")
        }
        let tiles = manifest.folders.map {
            ShortcutsEntry.Tile(path: $0.path, name: $0.name,
                                cover: WidgetStore.files(of: $0).first)
        }
        return ShortcutsEntry(date: Date(), tiles: tiles, size: size, message: nil)
    }
}

// MARK: - Rendering

struct ShortcutsView: View {
    let entry: ShortcutsEntry

    @Environment(\.widgetFamily) private var family

    private let gap: CGFloat = 2

    var body: some View {
        content
            .containerBackground(.black, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if entry.tiles.isEmpty {
            Text(entry.message ?? "Ouvre Keo pour remplir le widget")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            grid
        }
    }

    /// Three across — at 329 pt wide a fourth column leaves 78 pt a tile, where a folder name
    /// stops being readable. Large stacks a second row, but only if it has tiles to hold:
    /// an empty one would eat half the widget.
    private var grid: some View {
        let columns = 3
        let capacity = family == .systemLarge ? 2 : 1
        let shown = Array(entry.tiles.prefix(columns * capacity))
        let rows = stride(from: 0, to: shown.count, by: columns)
            .map { Array(shown[$0..<min($0 + columns, shown.count)]) }
        let width = (entry.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = (entry.size.height - CGFloat(rows.count - 1) * gap) / CGFloat(rows.count)

        return VStack(spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(row) { tile in
                        // `widgetURL` sets a single destination for the whole widget, so a
                        // grid of folders needs one `Link` per tile or every tile would open
                        // the same one.
                        Link(destination: WidgetManifest.link(folder: tile.path)
                                       ?? URL(string: "keo://")!) {
                            // The long edge, not the width: a tile of the large family is a
                            // portrait, and decoding to its width alone would upscale.
                            TileView(tile: tile, side: max(width, height), width: width)
                        }
                    }
                    // A row of two folders keeps the tile size of a row of three rather than
                    // stretching into portraits of nothing.
                    if row.count < columns { Spacer(minLength: 0) }
                }
            }
        }
    }
}

private struct TileView: View {
    let tile: ShortcutsEntry.Tile
    let side: CGFloat
    let width: CGFloat

    var body: some View {
        Photo(file: tile.cover, side: side)
            .frame(width: width)
            .overlay(alignment: .bottom) {
                Text(tile.name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                               startPoint: .top, endPoint: .bottom))
            }
    }
}
