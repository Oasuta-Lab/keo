import Foundation

/// Where a `keo://` URL lands. Pure, and outside SwiftUI, because the parsing is the part
/// that can quietly be wrong: a widget whose tap opens the root of the NAS looks like a
/// working widget.
///
/// The URLs are built by `WidgetManifest.link(folder:)` and `link(day:)`, in the app, and
/// read back here. Both ends therefore live in the repository — but the one that *emits*
/// them is copied into the extension, so the two can drift. The checks pin the round trip.
enum DeepLink: Equatable, Sendable {
    case folder(path: String)
    case day(Date)

    init?(_ url: URL) {
        guard url.scheme == "keo",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = parts.queryItems ?? []

        switch parts.host {
        case "folder":
            // An absolute path and nothing else: a relative one would be meaningless here,
            // and an empty one would open the root under the name of a folder.
            guard let path = query.first(where: { $0.name == "path" })?.value,
                  path.hasPrefix("/") else { return nil }
            self = .folder(path: path)
        case "day":
            guard let raw = query.first(where: { $0.name == "stamp" })?.value,
                  let seconds = TimeInterval(raw) else { return nil }
            self = .day(Date(timeIntervalSince1970: seconds))
        default:
            return nil
        }
    }

    /// The title a pushed folder carries. The last component, except at the root, which has
    /// none — and "/" would be a poor thing to print at the top of a screen.
    static func title(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
