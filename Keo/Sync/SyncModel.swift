import Foundation
import CryptoKit

/// The identity of one personalisation record, shared by every device.
///
/// The CloudKit record name is a stable hash of what the user actually did — "this file is a
/// favourite", "this folder is pinned" — so two devices adding the same favourite write the
/// *same* record. Adding becomes idempotent and the duplicate conflict disappears by
/// construction rather than by resolution.
///
/// A collection is identified by its *name*: renaming one is therefore a delete of the old
/// identity plus a save of the new one, members included. Costly in records but unambiguous —
/// two devices that each create "Vacances" offline end up with one collection, not two.
enum SyncIdentity: Equatable, Sendable {
    case favourite(path: String, size: Int64)
    case shortcut(path: String)
    case collection(name: String)
    case member(collection: String, path: String, size: Int64)

    /// NUL cannot appear in a path or a typed name, so the joined identity cannot collide.
    /// The prefix is only there so a record in the CloudKit dashboard says what it is.
    var recordName: String {
        let prefix: String, joined: String
        switch self {
        case .favourite(let path, let size):
            prefix = "fav"; joined = "favourite\u{0}\(path)\u{0}\(size)"
        case .shortcut(let path):
            prefix = "pin"; joined = "shortcut\u{0}\(path)"
        case .collection(let name):
            prefix = "col"; joined = "collection\u{0}\(name)"
        case .member(let collection, let path, let size):
            prefix = "mem"; joined = "member\u{0}\(collection)\u{0}\(path)\u{0}\(size)"
        }
        let digest = SHA256.hash(data: Data(joined.utf8))
        return prefix + "-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything one personalisation record carries, as plain data. This is what the journal
/// stores as JSON and what crosses between the SQLite actor and the CloudKit engine — CKRecord
/// itself is not Sendable and never leaves the sync layer.
struct SyncPayload: Codable, Equatable, Sendable {
    var kind: String
    var path: String?
    var name: String?
    var size: Int64?
    var added: Double?
    var collection: String?
    var created: Double?
    /// Wall-clock of the local write, the last-writer-wins stamp. Device clocks can drift;
    /// see `SyncConflict` for why that is survivable here.
    var modified: Double

    static func favourite(path: String, name: String, size: Int64,
                          added: Double, modified: Double) -> SyncPayload {
        SyncPayload(kind: "favourite", path: path, name: name, size: size, added: added,
                    collection: nil, created: nil, modified: modified)
    }

    static func shortcut(path: String, name: String, added: Double,
                         modified: Double) -> SyncPayload {
        SyncPayload(kind: "shortcut", path: path, name: name, size: nil, added: added,
                    collection: nil, created: nil, modified: modified)
    }

    static func collection(name: String, created: Double, modified: Double) -> SyncPayload {
        SyncPayload(kind: "collection", path: nil, name: name, size: nil, added: nil,
                    collection: nil, created: created, modified: modified)
    }

    static func member(collection: String, path: String, name: String, size: Int64,
                       added: Double, modified: Double) -> SyncPayload {
        SyncPayload(kind: "member", path: path, name: name, size: size, added: added,
                    collection: collection, created: nil, modified: modified)
    }

    /// Nil when the payload is incomplete for its kind — a record forged or truncated on the
    /// way in must be dropped, not half-applied.
    var identity: SyncIdentity? {
        switch kind {
        case "favourite":
            guard let path, let size else { return nil }
            return .favourite(path: path, size: size)
        case "shortcut":
            guard let path else { return nil }
            return .shortcut(path: path)
        case "collection":
            guard let name else { return nil }
            return .collection(name: name)
        case "member":
            guard let collection, let path, let size else { return nil }
            return .member(collection: collection, path: path, size: size)
        default:
            return nil
        }
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        // Deterministic output: the journal is compared in checks, and stable bytes make
        // "did anything change" questions answerable.
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decoded(from json: String) -> SyncPayload? {
        try? JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
    }
}

/// Conflict policy: last writer wins, per record, with a deliberate bias towards resurrection.
///
/// Clocks only ever break ties between two *saves* of the same record — and since the identity
/// is in the key, those two payloads describe the same user action and differ at most by their
/// `added` date. A skewed clock can therefore pick the other device's timestamp, never lose a
/// favourite. Deletions never consult a clock at all: a remote delete is skipped exactly when
/// this device still holds an unpushed save for the record (see `IndexStore.applyRemote`),
/// which is skew-proof.
enum SyncConflict {
    /// Ties go to the server so both devices converge on the same bytes.
    static func keepLocal(localModified: Double, serverModified: Double) -> Bool {
        localModified > serverModified
    }
}
