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
    /// Enough to fill a large mosaic and rotate through the day without repeating.
    static let perMemory = 12

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
            let covers = (try? await IndexStore.shared.recentMedia(under: pin.path,
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
            // Both optional in the manifest, and both genuinely unknown on a folder the
            // index has not finished: the widget omits what it is not given rather than
            // printing a zero that would read as "this folder is empty".
            let totals = (try? await IndexStore.shared.stats(for: [pin.path]))?[pin.path]
            folders.append(.init(path: pin.path, name: pin.name, images: names,
                                 mediaCount: totals?.mediaCount, span: totals?.span))
        }

        let memory = await renderMemories(client: client, into: directory, rendered: &rendered)

        // A folder unpinned months ago must not keep its photos in the container for ever.
        prune(directory, keeping: Set(folders.map { WidgetManifest.key(for: $0.path) }
                                    + [WidgetManifest.fileName, WidgetManifest.dayKey]))

        let manifest = WidgetManifest(version: WidgetManifest.currentVersion,
                                      stamped: Date(), folders: folders, onThisDay: memory)
        guard let encoded = try? JSONEncoder().encode(manifest) else { return }
        let file = directory.appendingPathComponent(WidgetManifest.fileName)
        try? encoded.write(to: file, options: .atomic)
        // An atomic write replaces the file, so the class has to be set on the new one.
        protect(file)

        trace("widget \(directory.path) folders=\(folders.count) rendered=\(rendered)")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Photos taken on this calendar day in years gone by.
    ///
    /// Rendered into one fixed directory rather than one per date: a directory per day of the
    /// year would quietly accumulate three hundred and sixty-five of them.
    private static func renderMemories(client: FreeboxClient, into directory: URL,
                                       rendered: inout Int) async -> WidgetManifest.Memory? {
        let today = Date()
        let found = (try? await IndexStore.shared.onThisDay(today, limit: 200)) ?? []
        let home = directory.appendingPathComponent(WidgetManifest.dayKey, isDirectory: true)
        guard !found.isEmpty else {
            // Nothing today: clear last day's photos rather than leave them to be shown
            // again under today's label.
            try? FileManager.default.removeItem(at: home)
            return nil
        }

        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        protect(home)

        let calendar = Calendar.current
        var names: [String] = []
        var years: [Int] = []
        for item in found.prefix(perMemory) {
            guard let capture = item.captureDate else { continue }
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
            years.append(calendar.component(.year, from: capture))
        }
        guard !names.isEmpty else { return nil }

        prune(home, keeping: Set(names))
        return .init(images: names, years: years, label: dayLabel(today), total: found.count)
    }

    /// Written by the app because the extension has no business formatting a date the app
    /// already knows how to write.
    private static func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: day)
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
