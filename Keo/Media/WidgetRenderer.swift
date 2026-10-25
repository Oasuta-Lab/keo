import UIKit
import WidgetKit

/// Pre-renders the pinned folders' most recent photos into the shared container.
///
/// Everything the widget needs is a file, because an extension that talks to the box is a bad
/// trade here. The app is LAN-only and the phone is off the home Wi-Fi most of the day, so a
/// networked widget would spend two thirds of its life rendering a failure. Sharing the token
/// would mean a keychain access group, and `Keychain.service` is the bundle identifier —
/// inside the extension that is `com.oasutalab.keo.KeoWidget`, which would silently look in
/// the wrong service. An extension gets 30 MB while `ThumbnailPipeline.still()` may fall back
/// to a 40 MB download. `NSLocalNetworkUsageDescription` in an `.appex` raises a *second*
/// permission dialog, attributed to something the owner cannot see. And an extension with no
/// `FreeboxClient` cannot write to the NAS even by accident.
enum WidgetRenderer {
    /// Twelve is a day of 30-minute entries plus slack, and it bounds what pinning a 14 600
    /// photo folder costs.
    static let perFolder = 12
    /// A large widget on the biggest iPad at 2×. Rendering higher only grows the container.
    static let maxPixel: CGFloat = 1200
    static let interval: TimeInterval = 3_600

    static func refresh(client: FreeboxClient, indexing: Bool) async {
        // The NAS reader is deliberately a single serial worker. A second one here would
        // bring back the doubled traffic that collapsing DateScan and Indexer removed.
        guard !indexing, let directory = WidgetManifest.directory else { return }

        let pinned = (try? await IndexStore.shared.shortcuts()) ?? []
        let signature = pinned.map(\.path).joined(separator: "\n")
        guard (try? await IndexStore.shared.claimWidgetRender(signature: signature,
                                                              interval: interval)) == true else {
            return
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        protect(directory)

        var folders: [WidgetManifest.Folder] = []
        var rendered = 0

        for pin in pinned {
            let covers = (try? await IndexStore.shared.covers(for: pin.path,
                                                              limit: perFolder)) ?? []
            guard !covers.isEmpty else { continue }

            let home = directory.appendingPathComponent(WidgetManifest.key(for: pin.path),
                                                        isDirectory: true)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            protect(home)

            var names: [String] = []
            for item in covers {
                let name = WidgetManifest.key(for: item.path)
                let file = home.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard let image = await ThumbnailPipeline.shared
                            .thumbnail(for: item, client: client, maxPixel: maxPixel),
                          let data = ImageDecoding.cacheData(for: image) else { continue }
                    try? data.write(to: file, options: .atomic)
                    protect(file)
                    rendered += 1
                }
                names.append(name)
            }
            guard !names.isEmpty else { continue }

            prune(home, keeping: Set(names))
            folders.append(.init(path: pin.path, name: pin.name, images: names))
        }

        // A folder unpinned months ago must not keep its photos in the container for ever.
        prune(directory, keeping: Set(folders.map { WidgetManifest.key(for: $0.path) }
                                    + [WidgetManifest.fileName]))

        let manifest = WidgetManifest(version: WidgetManifest.currentVersion,
                                      stamped: Date(), folders: folders)
        guard let encoded = try? JSONEncoder().encode(manifest) else { return }
        let file = directory.appendingPathComponent(WidgetManifest.fileName)
        try? encoded.write(to: file, options: .atomic)
        // An atomic write replaces the file, so the class has to be set on the new one.
        protect(file)

        trace("widget \(directory.path) folders=\(folders.count) rendered=\(rendered)")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Not `.complete`: the widget refreshes while the phone is locked, and files it could
    /// not open would blank it on every one of those refreshes.
    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func prune(_ directory: URL, keeping wanted: Set<String>) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for entry in entries where !wanted.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
