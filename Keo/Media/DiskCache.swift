import CryptoKit
import Foundation

/// Byte-budgeted store for rendered thumbnails. iOS may purge `Caches/` under pressure, but
/// left alone this directory grows without bound across a large library, so it trims itself.
struct DiskCache: Sendable {
    let directory: URL
    let budget: Int64

    init(name: String, budget: Int64) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.budget = budget
    }

    func url(for key: String) -> URL {
        // Not ".jpg": a thumbnail with transparency is stored as PNG.
        directory.appendingPathComponent(key).appendingPathExtension("thumb")
    }

    func read(_ key: String) -> Data? {
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        touch(file)
        return data
    }

    func write(_ data: Data, for key: String) {
        try? data.write(to: url(for: key), options: .atomic)
    }

    /// Least-recently-used eviction down to the budget. Called off the main thread at launch.
    func trim() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }

        let entries = files.compactMap { file -> Entry? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return Entry(url: file, lastUsed: used, size: Int64(values.fileSize ?? 0))
        }

        for victim in Self.evictions(from: entries, budget: budget) {
            try? FileManager.default.removeItem(at: victim)
        }
    }

    /// Reading marks a file as fresh, so trimming keeps what the user actually browses.
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    struct Entry: Sendable {
        let url: URL
        let lastUsed: Date
        let size: Int64
    }

    /// Pure, so the eviction policy can be checked without touching the filesystem.
    static func evictions(from entries: [Entry], budget: Int64) -> [URL] {
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budget else { return [] }

        var excess = total - budget
        var victims: [URL] = []
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard excess > 0 else { break }
            victims.append(entry.url)
            excess -= entry.size
        }
        return victims
    }

    /// `variant` separates thumbnails of the same file that were produced by different
    /// routes. It earned its place: thumbnails rendered from a truncated probe were blank,
    /// and fixing the renderer did not fix the library — the blanks were already on disk, and
    /// this directory outlives a reinstall. Changing the route changes the key, so the files
    /// that were wrong are re-rendered and the ones that were right are left alone.
    static func key(for path: String, size: Int64, maxPixel: Int,
                    variant: String = "") -> String {
        let seed = "\(path)|\(size)|\(maxPixel)" + (variant.isEmpty ? "" : "|\(variant)")
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
