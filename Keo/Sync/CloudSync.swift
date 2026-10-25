import CloudKit
import SwiftUI

/// Mirrors the personalisation tables — favourites, shortcuts, collections — to the user's
/// private CloudKit database, through `CKSyncEngine`.
///
/// SQLite stays the source of truth; CloudKit is a mirror of it. The engine owns everything
/// that is miserable to get right by hand: scheduling, batching, push subscriptions, retry
/// backoff (`retryAfter` is honoured internally), expired change tokens (it refetches on its
/// own), and account watching. What is left here is the part only Keo can decide: what a
/// record contains, who wins a conflict, and what an account change means for local data.
///
/// Never a blocking error. Without an iCloud account the app behaves exactly as it always
/// has, local only, with one quiet footnote on the personalisation tabs.
@MainActor
final class CloudSync: ObservableObject {
    enum Status: Equatable {
        case off              // no account, iCloud disabled for Keo, or restricted
        case recovering       // first fetch after a (re)install, local side still empty
        case syncing
        case upToDate
        case offline
        case error(String)
    }

    @Published private(set) var status: Status = .off

    nonisolated static let containerID = "iCloud.com.oasutalab.keo"
    nonisolated private static let recordType = "Personalisation"
    nonisolated private static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Personnalisation", ownerName: CKCurrentUserDefaultName)
    }

    private let store: IndexStore
    private var engine: CKSyncEngine?
    private var accountAvailable = false

    init(store: IndexStore = .shared) {
        self.store = store
    }

    func start() async {
        guard engine == nil else { return }

        let container = CKContainer(identifier: Self.containerID)
        let state = loadState()
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state == nil {
            // Brand new engine state: make sure our zone exists before anything is sent.
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }

        await store.setJournalObserver { [weak self] in
            Task { @MainActor in await self?.enqueueJournal() }
        }

        // `.noAccount`, `.restricted` (parental controls) and `.couldNotDetermine` all mean
        // the same thing to Keo: stay local, say so quietly, and let the engine's account
        // events wake us if that ever changes.
        let reachable = (try? await container.accountStatus()) ?? .couldNotDetermine
        accountAvailable = reachable == .available
        if accountAvailable {
            // May fail offline; then the binding simply happens on the next launch or on the
            // engine's sign-in event. Nothing is pushed to an unidentified account meanwhile
            // only if it differs — see `adopt`.
            if let user = try? await container.userRecordID() {
                await adopt(accountID: user.recordName)
            }
            try? await store.seedSyncJournalIfNeeded()
        }
        await enqueueJournal()
        await settleStatus()
    }

    // MARK: Local → engine

    /// Hands every journal row to the engine as a pending change. Idempotent: the engine
    /// de-duplicates by record ID, and a row only leaves the journal once acknowledged.
    private func enqueueJournal() async {
        guard let engine else { return }
        let pending = (try? await store.pendingSyncChanges()) ?? []
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map { change in
            let id = CKRecord.ID(recordName: change.recordName, zoneID: Self.zoneID)
            return change.op == .save ? .saveRecord(id) : .deleteRecord(id)
        })
        await settleStatus()
    }

    // MARK: Account identity

    /// Binds the local personalisation to one iCloud account. If a *different* account shows
    /// up, everything personal is wiped first: favourites are personal, and two people must
    /// never be mixed — neither the old data pushed up to the new account, nor the other way.
    /// Signing out wipes nothing: the device owner keeps their data, locally.
    private func adopt(accountID: String) async {
        let previous = try? await store.syncAccountID()
        if let previous, previous != accountID {
            try? await store.wipePersonalisation()
        }
        try? await store.setSyncAccountID(accountID)
    }

    // MARK: Status

    private func settleStatus() async {
        guard accountAvailable else {
            status = .off
            return
        }
        // "Empty because nothing has arrived yet" is not "empty because there is nothing":
        // until the first fetch completes, an empty database is shown as a recovery in
        // progress — otherwise a reinstalled user believes everything is lost and starts
        // over on top of it.
        let fetched = (try? await store.syncFetchedOnce()) ?? false
        let empty = (try? await store.personalisationIsEmpty()) ?? false
        if !fetched && empty {
            status = .recovering
            return
        }
        let pending = (try? await store.pendingSyncChanges()) ?? []
        if pending.isEmpty {
            status = .upToDate
            return
        }
        switch status {
        case .offline, .error: break   // the cause is known; keep naming it until it clears
        default: status = .syncing
        }
    }

    // MARK: Engine state persistence

    nonisolated private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keo", isDirectory: true)
            .appendingPathComponent("sync-state.json")
    }

    /// The engine's own memory of what has been sent and fetched. Losing it is not data loss
    /// — the journal is the belt to this suspender — but it would mean refetching everything.
    private func persist(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? FileManager.default.createDirectory(
            at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    }

    // MARK: CKRecord ↔ system-fields archive

    nonisolated private static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    nonisolated private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persist(update.stateSerialization)

        case .accountChange(let change):
            await handle(accountChange: change)

        case .fetchedDatabaseChanges(let changes):
            await handle(databaseChanges: changes)

        case .fetchedRecordZoneChanges(let changes):
            await apply(changes)

        case .sentRecordZoneChanges(let sent):
            await handle(sent: sent)

        case .willFetchChanges, .willSendChanges:
            if status != .recovering { status = .syncing }

        case .didFetchChanges:
            // From here on, an empty database genuinely means "nothing", and the recovery
            // state may never claim otherwise again.
            try? await store.setSyncFetchedOnce()
            await settleStatus()

        case .didSendChanges:
            await settleStatus()

        case .sentDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch? {
        let scoped = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
        let store = store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: scoped) { recordID in
            guard let change = try? await store.pendingSyncChange(recordName: recordID.recordName),
                  change.op == .save,
                  let json = change.payload,
                  let payload = SyncPayload.decoded(from: json) else {
                // The journal moved on — already acknowledged, or flipped to a delete that
                // is queued separately. Nothing to send under this name.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            // Build on the server's version when a conflict taught us one, so the save no
            // longer collides.
            let record = change.server.flatMap(Self.record(fromSystemFields:))
                ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            payload.fill(record)
            return record
        }
    }

    // MARK: Events

    private func handle(accountChange: CKSyncEngine.Event.AccountChange) async {
        switch accountChange.changeType {
        case .signIn(let user):
            accountAvailable = true
            await adopt(accountID: user.recordName)
            try? await store.seedSyncJournalIfNeeded()
            await enqueueJournal()
            await settleStatus()

        case .switchAccounts(_, let current):
            accountAvailable = true
            await adopt(accountID: current.recordName)   // wipes the previous person's data
            await settleStatus()

        case .signOut:
            // Local data stays: it belongs to whoever holds the device, and losing favourites
            // because iCloud was turned off would be the silent loss this design refuses.
            accountAvailable = false
            status = .off

        @unknown default:
            break
        }
    }

    private func handle(databaseChanges: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        for deletion in databaseChanges.deletions where deletion.zoneID == Self.zoneID {
            // The user deleted Keo's data from Réglages → iCloud → Stockage (or the
            // encryption keys were reset). Local SQLite is the source of truth: recreate the
            // zone and push everything back up, rather than letting the mirror's death kill
            // the original. Pending tombstones are preserved — see `journalAllPersonalisation`.
            engine?.state.add(pendingDatabaseChanges:
                [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try? await store.journalAllPersonalisation()
            await enqueueJournal()
        }
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        // CKRecord is not Sendable: reduced to plain payloads before crossing to the actor.
        let saves = changes.modifications.compactMap { SyncPayload(record: $0.record) }
        let deletes = changes.deletions.map { $0.recordID.recordName }
        guard !saves.isEmpty || !deletes.isEmpty else { return }
        try? await store.applyRemote(saves: saves, deletes: deletes)
    }

    private func handle(sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for record in sent.savedRecords {
            // Acknowledged — but only clear the journal row if it was not rewritten during
            // the round trip: a favourite re-toggled mid-flight must still be sent.
            let stamp = record.encryptedValues["modified"] as? Double ?? .greatestFiniteMagnitude
            try? await store.clearSyncPendingSave(recordName: record.recordID.recordName,
                                                  ifUnchangedSince: stamp)
        }
        for id in sent.deletedRecordIDs {
            try? await store.clearSyncPendingDelete(recordName: id.recordName)
        }

        var wentOffline = false
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // The per-record conflict: last writer wins. Equal identities mean the two
                // payloads describe the same user action, so either outcome keeps the record.
                guard let server = failure.error.serverRecord else { continue }
                let theirs = server.encryptedValues["modified"] as? Double ?? 0
                let ours = failure.record.encryptedValues["modified"] as? Double ?? 0
                if SyncConflict.keepLocal(localModified: ours, serverModified: theirs) {
                    try? await store.attachServerRecord(Self.systemFields(of: server),
                                                        to: id.recordName)
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                } else {
                    if let payload = SyncPayload(record: server) {
                        try? await store.applyRemote(saves: [payload], deletes: [])
                    }
                    try? await store.clearSyncPendingSave(recordName: id.recordName,
                                                          ifUnchangedSince: ours)
                }

            case .zoneNotFound:
                // Zone deleted between fetch and send: same answer as the fetched deletion.
                engine?.state.add(pendingDatabaseChanges:
                    [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                try? await store.journalAllPersonalisation()
                await enqueueJournal()

            case .unknownItem:
                // Our conflict base pointed at a record someone deleted meanwhile. Retry
                // fresh — the resurrection bias again: the save wins over the vanished record.
                try? await store.attachServerRecord(nil, to: id.recordName)
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])

            case .quotaExceeded:
                // The journal keeps the change; the engine retries when it can. The user is
                // told why nothing moves, once, in the footnote.
                status = .error("Stockage iCloud plein — vos favoris restent sur cet appareil "
                              + "en attendant.")

            case .networkFailure, .networkUnavailable:
                wentOffline = true

            case .limitExceeded:
                // A personalisation record is a few hundred bytes; one that exceeds CloudKit's
                // megabyte means corrupted input. Dropping it beats wedging the queue for ever.
                try? await store.clearSyncPendingSave(recordName: id.recordName,
                                                      ifUnchangedSince: .infinity)

            default:
                // serviceUnavailable, requestRateLimited, zoneBusy…: the engine reschedules
                // with the server's retryAfter on its own, and the journal still has the row.
                break
            }
        }

        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem:
                // Already gone — which is what we wanted.
                try? await store.clearSyncPendingDelete(recordName: id.recordName)
            case .zoneNotFound:
                // No zone, so nothing to delete in it.
                try? await store.clearSyncPendingDelete(recordName: id.recordName)
            case .networkFailure, .networkUnavailable:
                wentOffline = true
            default:
                break
            }
        }

        if wentOffline { status = .offline }
    }
}

// MARK: - CKRecord mapping

/// All fields ride in `encryptedValues`: personalisation names private files on a private
/// NAS, and nothing here ever needs a server-side query over field values.
private extension SyncPayload {
    init?(record: CKRecord) {
        guard let kind = record.encryptedValues["kind"] as? String,
              let modified = record.encryptedValues["modified"] as? Double else { return nil }
        self.init(kind: kind,
                  path: record.encryptedValues["path"] as? String,
                  name: record.encryptedValues["name"] as? String,
                  size: record.encryptedValues["size"] as? Int64,
                  added: record.encryptedValues["added"] as? Double,
                  collection: record.encryptedValues["collection"] as? String,
                  created: record.encryptedValues["created"] as? Double,
                  body: record.encryptedValues["body"] as? String,
                  modified: modified)
    }

    func fill(_ record: CKRecord) {
        record.encryptedValues["kind"] = kind
        record.encryptedValues["path"] = path
        record.encryptedValues["name"] = name
        record.encryptedValues["size"] = size
        record.encryptedValues["added"] = added
        record.encryptedValues["collection"] = collection
        record.encryptedValues["created"] = created
        record.encryptedValues["body"] = body
        record.encryptedValues["modified"] = modified
    }
}
