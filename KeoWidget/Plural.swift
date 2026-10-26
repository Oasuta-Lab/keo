import Foundation

/// « 1 élément », « 2 éléments », « 0 élément ».
///
/// Zero is singular in French, unlike English — that is the only subtlety, and it is
/// precisely the one the app's two rules had ended up writing differently: `n > 1` on the
/// app side, `n == 1 ? "" : "s"` on the widget side, which displayed « 0 photos ».
///
/// The number goes through `formatted()` rather than a bare interpolation, so that
/// thousands get their expected non-breaking space: « 8 380 éléments ».
enum Plural {
    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n > 1 ? many : one)"
    }
}
