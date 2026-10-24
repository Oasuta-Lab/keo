import SwiftUI

/// A minimap of the folder in time, pinned to the right edge.
///
/// Each period gets a segment whose height is its share of the photos, so the shape of the rail
/// *is* the distribution: a long stretch means a month you shot a lot, a hairline means a month
/// you barely did. Dragging it jumps straight to that period.
struct TimelineRail: View {
    let sections: [MediaSection]
    let activeID: MediaSection.ID?
    let onJump: (MediaSection.ID) -> Void

    @State private var dragging: MediaSection.ID?

    private static let railWidth: CGFloat = 3
    private static let activeWidth: CGFloat = 7
    private static let touchWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let bars = layout()

            ZStack(alignment: .topTrailing) {
                ForEach(bars, id: \.id) { bar in
                    segment(bar, height: height)
                }
                ForEach(bars.filter { $0.year != nil }, id: \.id) { bar in
                    Text(bar.year ?? "")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, Self.touchWidth - 20)
                        .offset(y: bar.start * height - 5)
                }
            }
            .frame(width: Self.touchWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(scrub(in: height, bars: bars))
            .overlay(alignment: .topTrailing) { bubble(bars: bars, height: height) }
        }
        .frame(width: Self.touchWidth)
        .padding(.trailing, 2)
    }

    // MARK: Pieces

    private func segment(_ bar: Bar, height: CGFloat) -> some View {
        let highlighted = bar.id == (dragging ?? activeID)
        return Capsule()
            .fill(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.45)))
            .frame(width: highlighted ? Self.activeWidth : Self.railWidth,
                   height: max(bar.height * height - 1.5, 1.5))
            .offset(y: bar.start * height)
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    @ViewBuilder
    private func bubble(bars: [Bar], height: CGFloat) -> some View {
        if let dragging, let bar = bars.first(where: { $0.id == dragging }) {
            Text(bar.title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .fixedSize()
                .offset(x: -Self.touchWidth, y: max(bar.start * height - 14, 0))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func scrub(in height: CGFloat, bars: [Bar]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard height > 0, let bar = bar(at: value.location.y / height, in: bars) else { return }
                guard bar.id != dragging else { return }
                dragging = bar.id
                onJump(bar.id)
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: Layout

    private struct Bar: Identifiable {
        let id: String
        let title: String
        let year: String?
        let start: CGFloat
        let height: CGFloat
    }

    /// Cumulative fractions computed in one pass; doing it per segment would be quadratic.
    private func layout() -> [Bar] {
        let total = CGFloat(max(sections.reduce(0) { $0 + $1.items.count }, 1))
        var cursor: CGFloat = 0
        return sections.map { section in
            let share = CGFloat(section.items.count) / total
            defer { cursor += share }
            return Bar(id: section.id, title: section.title, year: section.year,
                       start: cursor, height: share)
        }
    }

    private func bar(at fraction: CGFloat, in bars: [Bar]) -> Bar? {
        let clamped = min(max(fraction, 0), 0.9999)
        return bars.last { $0.start <= clamped } ?? bars.first
    }
}
