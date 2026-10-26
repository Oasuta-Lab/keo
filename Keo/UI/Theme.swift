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
    /// Keo's tint is now a terracotta, close enough to this that colour alone no longer carries
    /// the signal. Every use must pair it with a symbol — `exclamationmark.triangle`,
    /// `pause.circle` — so the meaning survives both the palette and colour-blind sight.
    static let warning = Color.orange
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

    /// The mark alone, without the tile the app icon sits on.
    private static let design = CGRect(x: 56, y: 58, width: 143, height: 136)

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
        for y in stride(from: CGFloat(66), through: 162, by: 32) {
            path.addRoundedRect(in: box(64, y, 38, 24),
                                cornerSize: CGSize(width: 5 * scale, height: 5 * scale))
        }

        // The arm is the outline of a 26-wide round-capped stroke. Letting the framework expand
        // it beats hand-computing the caps and the mitre, and it cannot drift from the icon.
        var arm = Path()
        arm.move(to: point(186, 78))
        arm.addLine(to: point(138, 126))
        arm.addLine(to: point(186, 174))
        path.addPath(arm.strokedPath(
            StrokeStyle(lineWidth: 26 * scale, lineCap: .round, lineJoin: .round)))
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

        var body: some View {
            CageMark()
                .fill(style: FillStyle(eoFill: true))
                .aspectRatio(CageMark.aspect, contentMode: .fit)
                .frame(height: height)
                .opacity(opacity)
                .accessibilityLabel("Keo")
        }
    }
}
