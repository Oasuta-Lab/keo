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
            let bars = layout(height: height)

            ZStack(alignment: .topTrailing) {
                // A continuous track so the rail reads as one object even where a period is
                // a hairline; without it the sparse months looked like rendering glitches.
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(width: Self.railWidth)

                ForEach(bars, id: \.id) { bar in
                    segment(bar, height: height)
                }
            }
            .frame(width: Self.touchWidth, alignment: .trailing)
            .overlay(alignment: .topTrailing) {
                // Outside the rail's own width, otherwise "2024" has 20 pt to render in and
                // comes out clipped. `fixedSize` keeps it on one line whatever the container.
                ForEach(yearLabels(bars, height: height), id: \.year) { label in
                    // No tick after the text: a short dash right after "2025" reads as a
                    // label whose value is missing.
                    Text(label.year)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .offset(x: -Self.touchWidth + 14, y: label.y)
                }
                .allowsHitTesting(false)
            }
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
            .fill(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.42)))
            .frame(width: highlighted ? Self.activeWidth : Self.railWidth,
                   height: max(bar.height * height - 2, 2))
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

    private func layout(height: CGFloat) -> [Bar] {
        let geometry = RailLayout.segments(counts: sections.map(\.items.count), height: height)
        return zip(sections, geometry).map { section, segment in
            Bar(id: section.id, title: section.title, year: section.year,
                start: segment.start, height: segment.height)
        }
    }

    private func yearLabels(_ bars: [Bar], height: CGFloat) -> [(year: String, y: CGFloat)] {
        RailLayout.yearPositions(
            years: bars.map(\.year),
            segments: bars.map { RailLayout.Segment(start: $0.start, height: $0.height) },
            height: height
        )
    }

    private func bar(at fraction: CGFloat, in bars: [Bar]) -> Bar? {
        let segments = bars.map { RailLayout.Segment(start: $0.start, height: $0.height) }
        guard let index = RailLayout.index(at: fraction, in: segments) else { return nil }
        return bars[index]
    }
}
