import SwiftUI

/// The handful of visual constants the app repeats, named once.
///
/// Everything else stays semantic — `.primary`, `.secondary`, materials, `Font.TextStyle` —
/// because those follow the system appearance and Dynamic Type for free. What lives here is
/// only what the system has no opinion about: how dark a veil over a photo is, how round a
/// card is, and which colour means "look at this".
///
/// The tint is deliberately absent: it is `AccentColor` in the asset catalog, so that a single
/// value tints the whole app including the controls SwiftUI draws itself.
enum Theme {

    /// Three steps, not the seven the app had grown. `tight` is for a thumbnail inside a row,
    /// `card` for anything you could tap as a unit, `panel` for a full-width block.
    enum Radius {
        static let tight: CGFloat = 8
        static let card: CGFloat = 14
        static let panel: CGFloat = 26
    }

    /// Black laid over a photograph so white text survives on top of it.
    ///
    /// Three values, because there are three jobs — and a photo app that uses six reads as six
    /// different hands. `veil` dims a whole tile, `chip` backs a small pill, `caption` is the
    /// bottom of the gradient under a caption.
    enum Scrim {
        static let veil: Double = 0.28
        static let chip: Double = 0.45
        static let caption: Double = 0.75
    }

    /// Something needs attention but nothing is broken: a stale index, a partial count, a disk
    /// nearly full.
    ///
    /// Keo's tint is a peach of almost exactly this luminance — 1.03:1 between the two, so
    /// against the brand they are the same shade of nothing. Colour alone cannot carry the
    /// signal here. Every use must pair it with a symbol — `exclamationmark.triangle`,
    /// `pause.circle` — so the meaning survives the palette and colour-blind sight alike.
    static let warning = Color.orange
}

extension Font {
    /// Montserrat Bold — the studio's face, on the word "Keo" and nowhere else.
    ///
    /// It stops there on purpose. Keo prints a great deal of metadata, and San Francisco is
    /// optically sized and carries tabular figures; the app leans on `.monospacedDigit()` in a
    /// dozen places where a counter must not jitter as it climbs, and Montserrat has no
    /// tabular numerals. Setting the interface in it would trade legibility at `.caption2`
    /// for a brand tie that one word already makes.
    ///
    /// `relativeTo:` is what keeps it scaling with Dynamic Type like everything else.
    static func wordmark(size: CGFloat) -> Font {
        .custom("Montserrat-Bold", size: size, relativeTo: .largeTitle)
    }
}

/// Keo's mark: four bays in a cage, and the arm of a K coming out of them.
///
/// A shape rather than an image, because it has to work at 20 pt in a header and at 96 pt on an
/// empty screen, take whatever colour it is given, and never ship a second file that drifts from
/// the app icon. The geometry is the icon's, on the same 256 grid — see `Design/icon/build.py`,
/// which is where it is authored.
///
/// The bays are holes, not lighter shapes, so the mark stays a single colour.
struct CageMark: Shape {

    /// Dropped for the small-size cut. Below roughly 30 pt the bays close up on their own,
    /// and set beside real letters a hollow stem stops reading as the stem of a K at all —
    /// it reads as a separate little ladder standing in front of the word.
    var bays = true

    /// The mark alone, without the tile the app icon sits on.
    fileprivate static let design = CGRect(x: 56, y: 58, width: 143, height: 136)

    private static let aspect = design.width / design.height

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.design.width, rect.height / Self.design.height)
        let size = CGSize(width: Self.design.width * scale, height: Self.design.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - Self.design.minX) * scale,
                    y: origin.y + (y - Self.design.minY) * scale)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: w * scale, height: h * scale))
        }

        var path = Path()
        path.addRoundedRect(in: box(56, 58, 54, 136),
                            cornerSize: CGSize(width: 14 * scale, height: 14 * scale))
        // Drawn in the same direction as the cage, so the even-odd fill cuts them out of it.
        if bays {
            for y in stride(from: CGFloat(66), through: 162, by: 32) {
                path.addRoundedRect(in: box(64, y, 38, 24),
                                    cornerSize: CGSize(width: 5 * scale, height: 5 * scale))
            }
        }

        return path
    }
}


/// The four bays on their own, so they can be filled as light keys instead of knocked through.
///
/// The icon builds the mark in two tones — a solid cage with light bays laid on it — and that
/// is what gives it its mass. Cut as holes the cage became a thin frame, which is why the mark
/// read as a ladder rather than as the logo.
struct CageMarkBays: Shape {
    func path(in rect: CGRect) -> Path {
        let design = CageMark.design
        let scale = min(rect.width / design.width, rect.height / design.height)
        let size = CGSize(width: design.width * scale, height: design.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)

        var path = Path()
        for y in stride(from: CGFloat(66), through: 162, by: 32) {
            let box = CGRect(x: origin.x + (64 - design.minX) * scale,
                             y: origin.y + (y - design.minY) * scale,
                             width: 38 * scale, height: 24 * scale)
            path.addRoundedRect(in: box,
                                cornerSize: CGSize(width: 5 * scale, height: 5 * scale))
        }
        return path
    }
}

/// The arm of the K, as a bare polyline meant to be stroked.
///
/// Deliberately not folded into `CageMark`: that path is filled even-odd so the bays read as
/// holes, and the outline of a round-capped stroke overlaps itself at the apex. Even-odd
/// cancels overlapping area, which punched a triangular hole in the corner of the V.
struct CageMarkArm: Shape {
    func path(in rect: CGRect) -> Path {
        let design = CageMark.design
        let scale = min(rect.width / design.width, rect.height / design.height)
        let size = CGSize(width: design.width * scale, height: design.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - design.minX) * scale,
                    y: origin.y + (y - design.minY) * scale)
        }

        var path = Path()
        path.move(to: point(186, 78))
        path.addLine(to: point(138, 126))
        path.addLine(to: point(186, 174))
        return path
    }
}

extension CageMark {
    /// The mark as a view, filled so the bays read as holes.
    ///
    /// Three places only, all of them "the app has nothing of yours to show yet": pairing, the
    /// first-launch welcome, and an indexing that has never been started. Plus the thumbnail
    /// that has not arrived from the NAS — the one empty rectangle a photo app produces by
    /// itself, where the mark can live without ever competing with a photograph.
    struct Filled: View {
        var height: CGFloat = 96
        var opacity: Double = 1
        var bays = true

        private var lineWidth: CGFloat { 26 * height / CageMark.design.height }

        /// Shadow spread, in step with the mark: a fixed radius is a canyon at 24 pt and
        /// invisible at 110.
        private var relief: CGFloat { max(0.5, height * 0.022) }

        /// Cage and arm: the ink of the mark.
        private var solid: some View {
            ZStack {
                CageMark(bays: false).fill(style: FillStyle(eoFill: true))
                CageMarkArm().stroke(style: StrokeStyle(
                    lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }

        var body: some View {
            ZStack {
                solid

                // Light keys laid on the plate, as the icon does it — not holes cut through
                // it. Each is sunk with an inner shadow: that is what turns four painted
                // rectangles into four bays with walls around them, and it is the thing the
                // flat drawing was missing.
                if bays {
                    CageMarkBays().fill(
                        Color(.systemBackground).shadow(
                            .inner(color: .black.opacity(0.45),
                                   radius: relief, y: relief * 0.6)))
                }
            }
            .aspectRatio(CageMark.aspect, contentMode: .fit)
            .frame(height: height)
            .opacity(opacity)
            .accessibilityLabel("Keo")
        }
    }
}
