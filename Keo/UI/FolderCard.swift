import SwiftUI

/// A folder shown as a tile: its cover, its name, and what the index knows about it.
///
/// One component for the browser grid and the home shelf, which used to be two. They had
/// already drifted — different plate colours, different placeholder glyphs, the count below the
/// name on one and nowhere on the other — so the same folder looked like two different things
/// depending on which screen you met it on.
///
/// The only genuine difference is the width: a shelf card is fixed so the row scrolls evenly,
/// a grid tile fills its column. Everything else follows from that, including how many lines
/// the name is allowed.
struct FolderCard: View {
    let folder: Item
    /// Absent until the folder has been indexed; the card simply says less.
    let stats: FolderStats?
    /// A photo from inside, picked by the index. Absent until a pass has seen one.
    let cover: Item?
    let client: FreeboxClient
    var noted = false
    /// Fixed on a shelf, nil in a grid.
    var width: CGFloat?

    @State private var image: UIImage?

    /// A grid aligns its tiles, so the name reserves both lines whether it needs them or not.
    /// A shelf scrolls horizontally and has no rows to align.
    private var nameLines: Int { width == nil ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.16))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.tint)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                style: .continuous))

                Badges(noted: noted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let count = stats?.mediaCount ?? folder.childCount, count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.weight(.medium))
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .task(id: cover?.path) {
                guard let cover else { return }
                // Default size on purpose: the cover then shares its cache entry with the grid
                // cell of the folder being opened, instead of fetching the same photo twice.
                let loaded = await ThumbnailPipeline.shared.thumbnail(for: cover, client: client)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }

            Text(folder.name)
                .font(.subheadline)
                .lineLimit(nameLines, reservesSpace: width == nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.horizontal, 2)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }

    /// "8,2 Go · 2019 – 2024", trimmed to whatever is actually known.
    private var detail: String? {
        guard let stats else { return nil }
        let parts = [
            stats.bytes.map { Int64($0).formatted(.byteCount(style: .file)) },
            stats.span,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
