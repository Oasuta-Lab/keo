import SwiftUI

/// A folder shown as a card: what it is, and what the index knows about it.
///
/// It used to lead with a photograph from inside. That cost a four-by-three plate of height
/// per folder and, worse, made a folder look like one more picture — on the home shelf
/// between a carousel and a row of photographs, and in the browser above a grid of them. The
/// card now says *folder* at a glance and spends its space on the three facts that tell two
/// folders apart: the name, how much is inside, and over which years.
///
/// One component for both places. They were briefly two, when the browser still showed covers
/// and the shelf did not; with the covers gone from both they do the same work again, and the
/// only genuine difference left is the width — fixed on a shelf that scrolls sideways, free in
/// a grid that has columns to fill.
struct FolderCard: View {
    let folder: Item
    /// Absent until the folder has been indexed; the card simply says less.
    let stats: FolderStats?
    /// Up to three photos from the subtree, best first. Empty until the folder is indexed.
    var covers: [Item] = []
    let client: FreeboxClient
    var noted = false
    /// Fixed on a shelf, nil in a grid.
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                if noted {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Contient une note")
                }
                Spacer(minLength: 0)
                // A hint of what is inside, not a presentation of it: small enough that the
                // card still reads as a folder first.
                Fan(items: covers, client: client)
            }

            Spacer(minLength: 10)

            Text(folder.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let count = stats?.mediaCount ?? folder.childCount, count > 0 {
                Text(Undoer.count(count, "élément", "éléments"))
                    .font(.caption2)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .padding(12)
        .background(.tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }

    /// "136,69 Go · 2016 – 2023", trimmed to whatever is actually known.
    private var detail: String? {
        guard let stats else { return nil }
        let parts = [
            stats.bytes.map { Int64($0).formatted(.byteCount(style: .file)) },
            stats.span,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Three photos from the folder, dealt like a hand of cards in the corner of its card.
///
/// Deliberately tiny and tilted. A single upright thumbnail is a cover — it takes over the
/// card and the folder stops looking like a folder, which is exactly what we moved away from.
/// A fan reads as "some of what is in here" and cannot be mistaken for the subject.
private struct Fan: View {
    let items: [Item]
    let client: FreeboxClient

    @State private var images: [String: UIImage] = [:]

    private static let side: CGFloat = 26
    /// How far each card is dealt past the one under it.
    private static let step: CGFloat = 6
    private static let tilt: Double = 9

    /// Rotating about the bottom-left corner swings the top-right one outwards, and that
    /// overhang is not in the view's own size — which is why the third card sat on the edge
    /// of the folder card. Counted here instead.
    private static var span: CGFloat {
        let overhang = side * CGFloat(sin(tilt * .pi / 180))
        return side + 2 * step + overhang + 2
    }

    var body: some View {
        let shown = Array(items.prefix(3))
        ZStack {
            // Reversed so the first — the best one the index picked — ends up on top.
            ForEach(Array(shown.enumerated()).reversed(), id: \.element.path) { index, item in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: Self.side, height: Self.side)
                    .overlay {
                        if let image = images[item.path] {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    // A hairline of the card's own ground, so three photos of the same beach
                    // still read as three.
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color(.systemBackground), lineWidth: 1)
                    }
                    .rotationEffect(.degrees(Double(index) * Self.tilt - Self.tilt),
                                    anchor: .bottomLeading)
                    .offset(x: CGFloat(index) * Self.step)
            }
        }
        .frame(width: Self.span, height: Self.side, alignment: .leading)
        .opacity(0.9)
        .accessibilityHidden(true)
        .task(id: shown.map(\.path)) {
            for item in shown where images[item.path] == nil {
                let loaded = await ThumbnailPipeline.shared.thumbnail(for: item, client: client)
                guard !Task.isCancelled else { return }
                guard let loaded else { continue }
                withAnimation(.easeOut(duration: 0.18)) { images[item.path] = loaded }
            }
        }
    }
}
