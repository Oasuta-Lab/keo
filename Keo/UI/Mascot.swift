import SwiftUI

/// The otter, in the only treatment that belongs inside the app.
///
/// The 3D render never appears here: photoreal fur beside SF Symbols and Liquid Glass reads as
/// a free-to-play splash screen, and it would date the app in two years. It lives on the App
/// Store icon, which is where a character belongs.
///
/// The flat cut-out is a different proposition — monochrome, scalable, dignified small. Being
/// a template image, it takes a colour instead of carrying one, which is what lets it survive
/// the app following the system appearance: cream on a dark field, brand blue on a light one,
/// where cream would be invisible.
///
/// Three places only, all of them "the app has nothing of yours to show yet": pairing, the
/// first-launch welcome, and an indexing that has never been started. Never on a screen with
/// photos on it — there, the photos are the soul.
struct Mascot: View {
    var height: CGFloat = 96
    var opacity: Double = 1

    @Environment(\.colorScheme) private var scheme

    private static let cream = Color(red: 0.96, green: 0.90, blue: 0.81)

    var body: some View {
        Image("Mascot")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(scheme == .dark ? Self.cream : Color.accentColor)
            .opacity(opacity)
            .accessibilityLabel("Keo, la loutre qui garde tes photos")
    }
}
