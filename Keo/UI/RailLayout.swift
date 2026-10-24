import CoreGraphics

/// Geometry of the timeline rail, kept free of SwiftUI so its edge cases can be checked.
enum RailLayout {
    /// Below this a period is a hairline: invisible, and impossible to hit with a thumb.
    static let minimumSegment: CGFloat = 5
    /// Fifteen years of photos used to stack fifteen chips over the grid. Labels now need
    /// real room, and the rail stays a rail rather than a column of text.
    static let minimumYearGap: CGFloat = 64
    static let edgeInset: CGFloat = 8
    static let labelHeight: CGFloat = 18

    struct Segment: Equatable {
        let start: CGFloat      // fraction of the rail, 0...1
        let height: CGFloat     // fraction of the rail
    }

    /// Every period gets a floor before the rest is shared out by photo count. Pure proportions
    /// looked right on paper but turned a quiet month into a one-pixel line.
    static func segments(counts: [Int], height: CGFloat) -> [Segment] {
        guard height > 0, !counts.isEmpty else { return [] }

        let values = counts.map { CGFloat(max($0, 0)) }
        let total = max(values.reduce(0, +), 1)
        let floor = minimumSegment / height
        let floors = floor * CGFloat(counts.count)

        // Too many periods to give everyone a floor: fall back to pure proportions.
        let shares: [CGFloat] = floors >= 1
            ? values.map { $0 / total }
            : values.map { floor + ($0 / total) * (1 - floors) }

        var cursor: CGFloat = 0
        return shares.map { share in
            defer { cursor += share }
            return Segment(start: cursor, height: share)
        }
    }

    /// Years close together would overlap into mush, so only the first of a cluster is drawn,
    /// and both ends are kept off the screen edges.
    static func yearPositions(years: [String?], segments: [Segment],
                              height: CGFloat) -> [(year: String, y: CGFloat)] {
        guard height > 0 else { return [] }
        let top = edgeInset
        let bottom = max(height - edgeInset - labelHeight, top)

        var placed: [(year: String, y: CGFloat)] = []
        var lastY = -minimumYearGap

        for (year, segment) in zip(years, segments) {
            guard let year else { continue }
            let y = min(max(segment.start * height - labelHeight / 2, top), bottom)
            guard y - lastY >= minimumYearGap else { continue }
            placed.append((year, y))
            lastY = y
        }
        return placed
    }

    /// Which period a touch at `fraction` down the rail refers to.
    static func index(at fraction: CGFloat, in segments: [Segment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(fraction, 0), 0.9999)
        return segments.lastIndex { $0.start <= clamped } ?? 0
    }
}
