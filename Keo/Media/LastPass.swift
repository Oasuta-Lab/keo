import Foundation

/// What went wrong, and where. A bare counter tells you something failed but never what,
/// which is no help at all when one folder out of eighty is unreachable.
///
/// Top-level rather than nested in `Indexer` because it outlives the walk that produced it:
/// `LastPass` carries it into the index, and the index is read from an actor, not the main one.
struct IndexProblem: Identifiable, Equatable, Sendable, Codable {
    enum Trouble: Equatable, Sendable, Codable {
        case folderUnreachable   // could not even be listed
        case fileUnreadable      // listed, but its bytes would not come
        case folderExcluded      // skipped on purpose, by `FolderExclusion`
    }

    var id: String { path }
    let path: String
    let reason: String
    let trouble: Trouble

    var name: String { (path as NSString).lastPathComponent }
}

/// What the last complete pass left behind.
///
/// It exists because Keo used to forget. The report was published once into a floating card,
/// the reader set it back to `nil`, and the problems lived in `Progress` — so they died with
/// the walk. Everything the app knew about indexing was therefore about the five percent of
/// the time a walk is actually running; the rest of the time the only honest thing left to say
/// was a total, and a total answers nothing.
///
/// Kept in the index's own `meta` table rather than in defaults: it describes the index, and
/// "tout relire depuis zéro" has to take it with it. A record written by an older build that
/// no longer decodes is simply absent — a missing report is a cosmetic loss, and failing to
/// open the screen over one would not be.
struct LastPass: Equatable, Sendable, Codable {
    var finishedAt: Date
    var summary: WalkSummary
    /// Folders the box would not list at all. Separate from `summary.unreadable`, which counts
    /// files that were listed and then refused their bytes.
    var unreachable = 0
    /// Never descended into, by rule. A count that suddenly jumps is how the owner catches a
    /// `FolderExclusion` rule that has become too greedy.
    var excluded = 0
    /// The first few in detail, capped upstream. The count above stays honest when this is
    /// shorter than it.
    var problems: [IndexProblem] = []

    /// True when something in the library needs looking at rather than just waiting.
    var hasTrouble: Bool { unreachable > 0 || summary.unreadable > 0 }

    func problems(_ trouble: IndexProblem.Trouble) -> [IndexProblem] {
        problems.filter { $0.trouble == trouble }
    }

    /// Seconds since 1970 rather than the encoder's default: the record crosses builds, and a
    /// date whose encoding changes is a record that silently stops decoding.
    static func decode(_ json: String) -> LastPass? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(LastPass.self, from: data)
    }

    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
