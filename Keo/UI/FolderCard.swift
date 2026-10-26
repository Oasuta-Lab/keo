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
    var noted = false
    /// Fixed on a shelf, nil in a grid.
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                if noted {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Contient une note")
                }
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
