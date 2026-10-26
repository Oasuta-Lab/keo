import Foundation
import SQLite3

/// SQLite tells the library "I own this buffer, copy it" with this sentinel.
private let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The metadata index: every photo's capture date, and which folders have been read.
///
/// Replaces a single JSON dictionary that was loaded whole into memory and rewritten in full
/// on every save. The problem was never the size, it was the granularity: the unit of writing
/// was "the entire index" and the unit of loss was "everything since the last save". Here a
/// batch of 256 files is one small transaction, and a kill at the worst possible moment costs
/// those 256 files, not the folder and the nine before it.
///
/// Everything — the connection and the prepared statements — stays inside this actor. The
/// SQLite pointers are not `Sendable` and must never leave.
actor IndexStore {
    static let shared = IndexStore()

    /// Files written per transaction. Small enough that a crash is cheap, large enough that
    /// the commit cost disappears into the network wait.
    static let batchSize = 256

    private var db: OpaquePointer?
    private var ready = false
    /// Injectable so checks can run against a throwaway directory.
    private let home: URL?

    init(directory: URL? = nil) {
        self.home = directory
    }

    // MARK: Opening

    private func open() throws {
        guard !ready else { return }

        let folder = home ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("index.sqlite")

        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw Failure.open(message)
        }

        // WAL survives a process kill without corruption; NORMAL trades an fsync per commit
        // for data we can always rebuild from the NAS.
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA busy_timeout = 3000")
        registerFold()
        registerStem()
        try exec(Self.schema)
        // Older databases predate the per-folder tallies; adding them is harmless if present.
        try? exec("ALTER TABLE folder ADD COLUMN media_count INTEGER")
        try? exec("ALTER TABLE folder ADD COLUMN bytes INTEGER")
        try? exec("ALTER TABLE file ADD COLUMN read INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE file ADD COLUMN kind INTEGER NOT NULL DEFAULT 3")
        // 0 until proven otherwise: a file wrongly hidden is a file lost.
        try? exec("ALTER TABLE file ADD COLUMN live INTEGER NOT NULL DEFAULT 0")
        // NULL on purpose, and nullable: "nobody has looked" is a third state, and the `kind`
        // migration already taught this file what a wrong default costs.
        try? exec("ALTER TABLE file ADD COLUMN cid TEXT")
        // Rows written before the column existed were all read ones.
        try? exec("UPDATE file SET read = 1 WHERE read = 0 AND gen >= 0 AND capture IS NOT NULL")

        // Readable while the phone is locked after the first unlock, like the rest of our data.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        ready = true
        retryDatelessAfterReaderChange()
        relistAfterListingChange()
        markLivePairsEverywhere()
        readIdentitiesAfterRuleChange()
        retryDatelessVideos()
        repairKinds()
        migrateFromJSON(in: folder)
        // Last, deliberately: the JSON migration above re-inserts paths recorded by a build
        // that had no exclusion rule at all, so the cleanup has to run after it.
        dropExcludedAfterRuleChange()
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS folder (
      id          INTEGER PRIMARY KEY,
      path        TEXT NOT NULL UNIQUE,
      mtime       REAL,
      child_count INTEGER,
      media_count INTEGER,
      bytes       INTEGER,
      gen         INTEGER NOT NULL DEFAULT 0
    );
    -- Quand Keo a vu ce fichier pour la premiere fois.
    --
    -- Une table a part, et non une colonne de `file`, parce que « Tout relire depuis zero »
    -- fait `DELETE FROM file` : la date d'arrivee y serait effacee, et le re-parcours
    -- tamponnerait toute la bibliotheque de l'instant de la reconstruction. C'est un fait sur
    -- l'histoire du fichier, pas sur la generation d'index en cours.
    --
    -- Rien ici pour ce qui etait deja indexe avant : une absence est plus honnete qu'une date
    -- inventee, et l'etagere se remplit au fil des arrivees.
    CREATE TABLE IF NOT EXISTS arrival (
      folder_id INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
      name      TEXT    NOT NULL,
      size      INTEGER NOT NULL,
      added     REAL    NOT NULL,
      PRIMARY KEY (folder_id, name, size)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS file (
      folder_id INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
      name      TEXT    NOT NULL,
      size      INTEGER NOT NULL,
      capture   REAL,
      -- 0 = seen in a listing but never read. Distinguishes "no EXIF date" from "not read
      -- yet", which a nullable capture alone cannot express.
      read      INTEGER NOT NULL DEFAULT 0,
      -- 3 = "other": a default must never claim a file is a folder.
      kind      INTEGER NOT NULL DEFAULT 3,
      gen       INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (folder_id, name, size)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS file_by_identity ON file(name, size);
    CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v);

    -- Favourites, shortcuts and collections are keyed on the path itself rather than on a
    -- folder row. They must outlive the index: a sweep, a rebuild, or a folder that vanishes
    -- for an evening must never take someone's favourites with it.
    CREATE TABLE IF NOT EXISTS favourite (
      path  TEXT    NOT NULL,
      name  TEXT    NOT NULL,
      size  INTEGER NOT NULL,
      added REAL    NOT NULL,
      PRIMARY KEY (path, size)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS shortcut (
      path  TEXT PRIMARY KEY,
      name  TEXT NOT NULL,
      added REAL NOT NULL
    );

    -- A note is the one piece of personalisation whose *content* changes, so unlike a
    -- favourite it carries its own `modified`: presence no longer settles a conflict, the
    -- text does. Keyed like a favourite so a note follows a file that moves.
    CREATE TABLE IF NOT EXISTS note (
      path     TEXT    NOT NULL,
      name     TEXT    NOT NULL,
      size     INTEGER NOT NULL,
      body     TEXT    NOT NULL,
      modified REAL    NOT NULL,
      PRIMARY KEY (path, size)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS collection (
      id      INTEGER PRIMARY KEY,
      name    TEXT NOT NULL UNIQUE,
      created REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS collection_item (
      collection_id INTEGER NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
      path  TEXT    NOT NULL,
      name  TEXT    NOT NULL,
      size  INTEGER NOT NULL,
      added REAL    NOT NULL,
      PRIMARY KEY (collection_id, path, size)
    ) WITHOUT ROWID;

    -- The sync journal: one row per personalisation record that differs from what CloudKit
    -- last acknowledged. Written in the same transaction as the change itself, so a kill
    -- can never lose a change nor send one twice: a row survives until the server has
    -- confirmed it, and re-sending an already-applied row is idempotent by record name.
    -- `server` carries the CloudKit system fields after a conflict, so the retry can build
    -- on the server's version instead of colliding with it again.
    CREATE TABLE IF NOT EXISTS sync_pending (
      record_name TEXT PRIMARY KEY,
      op      INTEGER NOT NULL,      -- 0 save, 1 delete
      payload TEXT,                  -- SyncPayload JSON for saves, NULL for deletes
      changed REAL NOT NULL,
      server  BLOB
    );
    """

    // MARK: Generations

    /// A pass stamps everything it sees with one number; whatever still carries an older one
    /// has disappeared from the NAS and is swept away.
    func beginGeneration() throws -> Int64 {
        try open()
        let next = (try value(forKey: "generation") ?? 0) + 1
        try setValue(next, forKey: "generation")
        return next
    }

    func sweepFolders(generation: Int64) throws {
        try open()
        // Keeps folders never walked (gen 0) so an interrupted first pass isn't wiped.
        try exec("DELETE FROM folder WHERE gen > 0 AND gen < \(generation)")
    }

    // MARK: Reading

    func fileCount() throws -> Int {
        try open()
        return Int(try scalar("SELECT count(*) FROM file") ?? 0)
    }

    func isUnchanged(_ path: String, modified: Date?, childCount: Int?) throws -> Bool {
        try open()
        guard let modified else { return false }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT mtime, child_count FROM folder WHERE path = ?", into: &statement)
        bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return false }

        let stamp = sqlite3_column_double(statement, 0)
        guard FolderStamp.isUnchanged(recorded: stamp, modified: modified) else { return false }

        // Belt and braces: some servers are lazy about directory mtimes.
        if let childCount, sqlite3_column_type(statement, 1) != SQLITE_NULL {
            return Int(sqlite3_column_int64(statement, 1)) == childCount
        }
        return true
    }

    /// Capture dates already known for this folder's files.
    func known(_ items: [Item], in folder: String) throws -> [Item.ID: Date] {
        try open()
        guard let id = try folderID(folder, create: false), !items.isEmpty else { return [:] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT capture FROM file
            WHERE folder_id = ? AND name = ? AND size = ? AND read = 1
            """, into: &statement)

        var found: [Item.ID: Date] = [:]
        for item in items {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, id)
            bind(statement, 2, item.name)
            sqlite3_bind_int64(statement, 3, item.size)
            if sqlite3_step(statement) == SQLITE_ROW,
               sqlite3_column_type(statement, 0) != SQLITE_NULL {
                found[item.id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
        }
        return found
    }

    /// Items with no row at all — never read, or read and failed.
    func unread(_ items: [Item], in folder: String) throws -> [Item] {
        try open()
        guard let id = try folderID(folder, create: false) else { return items }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT 1 FROM file WHERE folder_id = ? AND name = ? AND size = ? AND read = 1
            """, into: &statement)

        return items.filter { item in
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, id)
            bind(statement, 2, item.name)
            sqlite3_bind_int64(statement, 3, item.size)
            return sqlite3_step(statement) != SQLITE_ROW
        }
    }

    /// Looks for the same file under another folder — a rename or a move. Renaming a folder of
    /// 14 600 photos used to invalidate every key and cost hours of re-reading; here it is a
    /// handful of milliseconds of index lookups.
    ///
    /// Ambiguous matches (same name and size, different dates) are left out: re-reading the
    /// file is cheap and certain.
    func adopt(_ items: [Item]) throws -> [Item.ID: Date] {
        try open()
        guard !items.isEmpty else { return [:] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT capture, count(DISTINCT ifnull(capture, -1)) FROM file
            WHERE name = ? AND size = ? AND capture IS NOT NULL
            """, into: &statement)

        var found: [Item.ID: Date] = [:]
        for item in items {
            sqlite3_reset(statement)
            bind(statement, 1, item.name)
            sqlite3_bind_int64(statement, 2, item.size)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_int64(statement, 1) == 1 else { continue }
            found[item.id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
        return found
    }

    // MARK: Writing

    /// One transaction: the dates, the folder's own generation, and — when the folder was read
    /// end to end — its completion stamp. That stamp can therefore never outlive the rows it
    /// claims, whatever happens to the process.
    /// `present` is every file the listing showed. Bumping their generation before sweeping is
    /// what makes the sweep mean "gone from the NAS" rather than "not re-read this time" — a
    /// date picked up opportunistically by the thumbnail pipeline would otherwise be deleted.
    func commit(_ results: [(item: Item, capture: Date?)], in folder: String,
                generation: Int64, stamp: FolderStamp.Completion? = nil,
                present: [Item] = [], sweep: Bool = false) throws {
        try open()
        // One instant for the whole pass, not one per row: files that arrive together did
        // arrive together, and a shelf of "recent additions" reads better when a folder that
        // landed in one copy keeps its order by name rather than by microsecond.
        let now = Date().timeIntervalSince1970
        try exec("BEGIN IMMEDIATE")
        do {
            let id = try folderID(folder, create: true)!
            try exec("UPDATE folder SET gen = \(generation) WHERE id = \(id)")

            if !results.isEmpty {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare("""
                    INSERT INTO file (folder_id, name, size, capture, read, kind, gen, cid)
                    VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                    ON CONFLICT(folder_id, name, size)
                    DO UPDATE SET capture = excluded.capture, read = 1,
                                  kind = excluded.kind, gen = excluded.gen,
                                  -- An unread pass must not erase what a read one learned.
                                  cid = coalesce(excluded.cid, file.cid)
                    """, into: &statement)

                for (item, capture) in results {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, id)
                    bind(statement, 2, item.name)
                    sqlite3_bind_int64(statement, 3, item.size)
                    if let capture {
                        sqlite3_bind_double(statement, 4, capture.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    sqlite3_bind_int64(statement, 5, Int64(item.kind.code))
                    sqlite3_bind_int64(statement, 6, generation)
                    if let cid = item.contentID {
                        bind(statement, 7, cid)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
                }
            }

            if !present.isEmpty {
                var mark: OpaquePointer?
                defer { sqlite3_finalize(mark) }
                // Insert rather than update: the database then mirrors the whole listing, which
                // is what lets a folder be painted before the box has answered.
                try prepare("""
                    INSERT INTO file (folder_id, name, size, capture, read, kind, gen)
                    VALUES (?, ?, ?, NULL, 0, ?, ?)
                    ON CONFLICT(folder_id, name, size) DO UPDATE SET gen = excluded.gen
                    """, into: &mark)
                for item in present {
                    sqlite3_reset(mark)
                    sqlite3_bind_int64(mark, 1, id)
                    bind(mark, 2, item.name)
                    sqlite3_bind_int64(mark, 3, item.size)
                    sqlite3_bind_int64(mark, 4, Int64(item.kind.code))
                    sqlite3_bind_int64(mark, 5, generation)
                    guard sqlite3_step(mark) == SQLITE_DONE else { throw Failure.write(message) }
                }
            }
            // `OR IGNORE` est toute la regle : une arrivee deja notee ne se renote pas. C'est
            // ce qui fait qu'un second passage — ou une reconstruction complete, qui vide
            // `file` mais pas cette table — ne deplace pas la date.
            let arriving = results.map(\.item) + present
            if !arriving.isEmpty {
                var note: OpaquePointer?
                defer { sqlite3_finalize(note) }
                try prepare("""
                    INSERT OR IGNORE INTO arrival (folder_id, name, size, added)
                    VALUES (?, ?, ?, ?)
                    """, into: &note)
                for item in arriving {
                    sqlite3_reset(note)
                    sqlite3_bind_int64(note, 1, id)
                    bind(note, 2, item.name)
                    sqlite3_bind_int64(note, 3, item.size)
                    sqlite3_bind_double(note, 4, now)
                    guard sqlite3_step(note) == SQLITE_DONE else { throw Failure.write(message) }
                }
            }

            if sweep {
                try exec("DELETE FROM file WHERE folder_id = \(id) AND gen < \(generation)")
            }
            if let stamp { try stampFolder(id, stamp) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Whether the index knows of any folder nested under this one.
    ///
    /// Skipping an unchanged folder also skips listing it, which means never discovering its
    /// children — a parent whose own files were read would hide an unfinished subtree and let
    /// the pass believe it had reached the end. Only a folder with no known children may be
    /// skipped outright.
    func hasChildFolders(_ folder: String) throws -> Bool {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM folder WHERE " + Self.subtree() + " LIMIT 1", into: &statement)
        bindSubtree(statement, folder, low: 1, high: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Everything strictly inside a folder, matched on a prefix rather than with `LIKE`: a
    /// path may legitimately contain `%` or `_`.
    ///
    /// `?1` is the prefix, built by `Statistics.scopePrefix`, and never the folder path. The
    /// root is `/`, where the obvious `?1 || '/'` spells `//` and prefixes nothing at all —
    /// the root then came back childless, which `Tests/stats.swift` pins down.
    ///
    /// The length guard is what keeps "strictly inside" true once the prefix is `/`: the root
    /// row matches its own prefix, and without it the root listed itself as one of its own
    /// subfolders — a tile you could tap into forever. Callers that do want the folder itself
    /// say so with an explicit `path = ?n OR` next to this.
    private static func subtree(_ column: String = "path",
                               low: Int = 1, high: Int = 2) -> String {
        // A range, not a `substr`. Wrapping the column in function calls makes the predicate
        // unusable by the index on `path`, so every one of the seven call sites scanned the
        // whole table — and `hasChildFolders` ran once per folder of the walk. `?1` is the
        // prefix and `?2` its successor, so the bounds seek straight into the index.
        "\(column) > ?\(low) AND \(column) < ?\(high)"
    }

    /// The smallest string strictly greater than every path under this prefix: the prefix
    /// with its last byte incremented. `/Photos/` becomes `/Photos0`, and at the root `/`
    /// becomes `0` — which is exactly right, since `/` is 0x2F and `0` is 0x30.
    /// Binds both ends of a subtree range at once, so a call site cannot bind one and
    /// forget the other — which would silently return nothing at all.
    private func bindSubtree(_ statement: OpaquePointer?, _ folder: String,
                             low: Int32, high: Int32) {
        let prefix = Statistics.scopePrefix(folder)
        bind(statement, low, prefix)
        bind(statement, high, Self.upperBound(prefix))
    }

    private static func upperBound(_ prefix: String) -> String {
        var bytes = Array(prefix.utf8)
        guard let last = bytes.last else { return prefix }
        bytes[bytes.count - 1] = last &+ 1
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The folder as the last pass saw it. Lets the grid appear immediately, before the box
    /// has had a chance to answer — and it answers in seconds on a folder of 14 600 files.
    func listing(_ folder: String) throws -> [Item] {
        try open()
        guard let id = try folderID(folder, create: false) else { return [] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Companions included, deliberately. `FolderContents` is what hides them, and it is
        // the same code that hides them in a fresh listing from the box — so a folder opened
        // from the cache shows exactly what it shows once the box has answered, Live Photo
        // badges and playable videos and all. The `live` column is for the queries that have
        // no `FolderContents` to lean on: search, covers, counts.
        try prepare("""
            SELECT name, size, capture, kind, cid FROM file WHERE folder_id = ?
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, id)

        var items: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: raw)
            let capture = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            var item = Item(
                path: folder + "/" + name,
                name: name,
                isDirectory: false,
                size: sqlite3_column_int64(statement, 1),
                modified: nil,
                mimeType: Item.Kind(code: Int(sqlite3_column_int64(statement, 3)))?.mimeHint,
                captureDate: capture
            )
            if let raw = sqlite3_column_text(statement, 4) { item.contentID = String(cString: raw) }
            items.append(item)
        }

        var children: OpaquePointer?
        defer { sqlite3_finalize(children) }
        try prepare("SELECT path FROM folder WHERE " + Self.subtree(), into: &children)
        bindSubtree(children, folder, low: 1, high: 2)
        while sqlite3_step(children) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(children, 0) else { continue }
            let path = String(cString: raw)
            // Direct children only.
            guard (path as NSString).deletingLastPathComponent == folder else { continue }
            items.append(Item(path: path, name: (path as NSString).lastPathComponent,
                              isDirectory: true, size: 0, modified: nil,
                              mimeType: "inode/directory"))
        }
        return items
    }

    /// Copies onto a fresh listing what the index already knows — capture dates and Live
    /// identifiers. A listing straight from the box carries neither, so without this the
    /// pairing inside `FolderContents` fell back to the name rule on every refresh: a video
    /// the identifiers had freed was visible from the cache and hidden again seconds later.
    /// The rule can only hold in its three places if all three see the same evidence.
    func enrich(_ items: [Item], in folder: String) throws -> [Item] {
        try open()
        guard let id = try folderID(folder, create: false) else { return items }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT name, size, capture, cid FROM file WHERE folder_id = ?",
                    into: &statement)
        sqlite3_bind_int64(statement, 1, id)

        var known: [String: (capture: Date?, cid: String?)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let capture = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let cid = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            known["\(sqlite3_column_int64(statement, 1))|\(String(cString: raw))"] =
                (capture, cid)
        }
        guard !known.isEmpty else { return items }

        return items.map { item in
            guard let hit = known["\(item.size)|\(item.name)"] else { return item }
            var copy = item
            if copy.captureDate == nil { copy.captureDate = hit.capture }
            if copy.contentID == nil { copy.contentID = hit.cid }
            return copy
        }
    }

    /// A date noticed in passing by the thumbnail pipeline, which already holds the file's
    /// first bytes. Written with the folder's current generation so the next sweep keeps it.
    func note(_ capture: Date?, for item: Item, in folder: String) throws {
        try open()
        let generation = try folderGeneration(folder)
        try commit([(item, capture)], in: folder, generation: generation)
    }

    private func folderGeneration(_ folder: String) throws -> Int64 {
        guard let id = try folderID(folder, create: false) else {
            return try value(forKey: "generation") ?? 0
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT gen FROM folder WHERE id = ?", into: &statement)
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// Marks a whole subtree as still present, for a folder skipped because it had not changed.
    ///
    /// The subfolders matter as much as the files: we never list them, so without this their
    /// generation would stay behind and the end-of-pass sweep would delete them — taking their
    /// photos with them through the cascade.
    func touchSubtree(_ folder: String, generation: Int64) throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            let scope = "path = ?3 OR " + Self.subtree(low: 1, high: 4)

            var folders: OpaquePointer?
            defer { sqlite3_finalize(folders) }
            try prepare("UPDATE folder SET gen = ?2 WHERE " + scope, into: &folders)
            bindSubtree(folders, folder, low: 1, high: 4)
            sqlite3_bind_int64(folders, 2, generation)
            bind(folders, 3, folder)
            guard sqlite3_step(folders) == SQLITE_DONE else { throw Failure.write(message) }

            var files: OpaquePointer?
            defer { sqlite3_finalize(files) }
            let sql = "UPDATE file SET gen = ?2 WHERE folder_id IN "
                    + "(SELECT id FROM folder WHERE " + scope + ")"
            try prepare(sql, into: &files)
            bind(files, 1, Statistics.scopePrefix(folder))
            sqlite3_bind_int64(files, 2, generation)
            bind(files, 3, folder)
            guard sqlite3_step(files) == SQLITE_DONE else { throw Failure.write(message) }

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Forgets every completion stamp, so the next pass lists every folder again. Dates
    /// already read are kept — nothing is re-downloaded that is already known.
    func forgetWalk() throws {
        try open()
        try exec("UPDATE folder SET mtime = NULL, child_count = NULL")
    }

    /// Throws away every date ever read. Hours of work on a large library, hence the
    /// confirmation in front of it.
    func forgetEverything() throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM file")
            try exec("UPDATE folder SET mtime = NULL, child_count = NULL, "
                   + "media_count = NULL, bytes = NULL")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Flushes the write-ahead log so the file at rest is compact and backups see it whole.
    func checkpoint() {
        guard ready else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// How much of a file the date reader looks at. Bumping this re-queues every file that
    /// came back without a date, because a better reader may now find one — the old 4 KB
    /// probe missed 61 % of them, and those rows would otherwise stay wrong for ever.
    /// Bumped when a pass must relist every folder — not re-read a single file. Documents
    /// were counted but never recorded, so folders stamped before that stay complete forever
    /// and their files would never appear. Clearing the stamp costs one listing per folder.
    private static let listingVersion: Int64 = 1

    private func relistAfterListingChange() {
        guard let seen = try? value(forKey: "listingVersion") ?? 0,
              seen < Self.listingVersion else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            // Only the stamp: `read = 1` is untouched, so no photo is read a second time.
            try exec("UPDATE folder SET mtime = NULL")
            try setValue(Self.listingVersion, forKey: "listingVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    /// Re-reads the videos the index holds without a date.
    ///
    /// Measured on 120 real dateless files: 111 genuinely carry no capture date — they are
    /// screenshots, downloads, received images, and no window will ever find one. But **7 of
    /// the 8 videos read perfectly today**, so their blank is a past failure, not a fact
    /// about the file: a dropped read or a shorted range at the moment they were indexed.
    ///
    /// Videos only, deliberately. Re-queueing every dateless file would re-read 1 584 of them
    /// to recover the hundred that are videos; this re-reads the hundred.
    private static let videoRetryVersion: Int64 = 1

    private func retryDatelessVideos() {
        guard let seen = try? value(forKey: "videoRetryVersion") ?? 0,
              seen < Self.videoRetryVersion else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            try exec("""
                UPDATE file SET read = 0
                WHERE kind = \(Item.Kind.video.code) AND read = 1 AND capture IS NULL
                """)
            try exec("""
                UPDATE folder SET mtime = NULL WHERE id IN
                (SELECT DISTINCT folder_id FROM file WHERE read = 0)
                """)
            try setValue(Self.videoRetryVersion, forKey: "videoRetryVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    private static let readerVersion: Int64 = 3

    private func retryDatelessAfterReaderChange() {
        guard let seen = try? value(forKey: "readerVersion") ?? 0,
              seen < Self.readerVersion else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            // Only the dateless ones: a date already found is still a date.
            try exec("UPDATE file SET read = 0 WHERE read = 1 AND capture IS NULL")
            // Their folders can no longer claim to be complete.
            try exec("""
                UPDATE folder SET mtime = NULL WHERE id IN
                (SELECT DISTINCT folder_id FROM file WHERE read = 0)
                """)
            try setValue(Self.readerVersion, forKey: "readerVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    /// Bumped when `FolderExclusion` changes. What the walk no longer descends into must also
    /// leave the index, or the counts, the weights, the statistics and the search keep showing
    /// dev detritus indexed by an earlier version — the owner's index held 4 799 folders when
    /// the rule was written. One scan of `folder`, once.
    ///
    /// Only `folder` rows are deleted; `file` follows by cascade. Favourites, collections,
    /// shortcuts and notes are keyed on the path and hold no foreign key to `folder`: they are
    /// deliberately outside the index's lifetime, and nothing here may reach them.
    private static let exclusionVersion: Int64 = 1

    private func dropExcludedAfterRuleChange() {
        guard let seen = try? value(forKey: "exclusionVersion") ?? 0,
              seen < Self.exclusionVersion else { return }
        do {
            let doomed = try excludedFolderIDs()
            try exec("BEGIN IMMEDIATE")
            // The ids come from the database, so interpolating them cannot inject anything —
            // same reasoning as `sweepFolders`.
            for id in doomed { try exec("DELETE FROM folder WHERE id = \(id)") }
            try setValue(Self.exclusionVersion, forKey: "exclusionVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    /// Collected before deleting anything: a statement cannot be stepped while the table it
    /// reads is being emptied underneath it.
    private func excludedFolderIDs() throws -> [Int64] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id, path FROM folder", into: &statement)

        var doomed: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1),
                  FolderExclusion.excludes(path: String(cString: raw)) else { continue }
            doomed.append(sqlite3_column_int64(statement, 0))
        }
        return doomed
    }

    /// Rows written before `kind` existed inherited 0, which means "folder" — so every photo
    /// already indexed came back from the cache as a folder you could tap into. The name is
    /// enough to work out what they really are.
    private func repairKinds() {
        guard let broken = try? rowsWithUnknownKind(), !broken.isEmpty else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("UPDATE file SET kind = ? WHERE folder_id = ? AND name = ? AND size = ?",
                        into: &statement)
            for row in broken {
                let kind = Item(path: row.name, name: row.name, isDirectory: false,
                                size: row.size, modified: nil, mimeType: nil).kind
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, Int64(kind.code))
                sqlite3_bind_int64(statement, 2, row.folder)
                bind(statement, 3, row.name)
                sqlite3_bind_int64(statement, 4, row.size)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    private func rowsWithUnknownKind() throws -> [(folder: Int64, name: String, size: Int64)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT folder_id, name, size FROM file WHERE kind = 0", into: &statement)

        var rows: [(folder: Int64, name: String, size: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            rows.append((sqlite3_column_int64(statement, 0), String(cString: raw),
                         sqlite3_column_int64(statement, 2)))
        }
        return rows
    }

    #if DEBUG
    /// Recreates a database written by an older, worse date reader.
    func rewindReaderVersionForChecks() throws {
        try open()
        try setValue(0, forKey: "readerVersion")
    }

    /// Recreates the state of a database written before `kind` existed.
    func rewriteKindsAsUnknownForChecks() throws {
        try open()
        try exec("UPDATE file SET kind = 0")
    }

    /// Replays the one-pass cleanup on a database written before the exclusion rule existed.
    /// `open()` runs it once and only once, which is exactly what a check cannot work with.
    func replayExclusionCleanupForChecks() throws {
        try open()
        try setValue(0, forKey: "exclusionVersion")
        dropExcludedAfterRuleChange()
    }
    #endif

    // MARK: Favourites, shortcuts, collections

    struct Collection: Identifiable, Equatable, Sendable {
        let id: Int64
        let name: String
        let count: Int
    }

    func isFavourite(_ item: Item) throws -> Bool {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM favourite WHERE path = ? AND size = ?", into: &statement)
        bind(statement, 1, item.path)
        sqlite3_bind_int64(statement, 2, item.size)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func setFavourite(_ items: [Item], _ on: Bool) throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(on
                ? "INSERT OR IGNORE INTO favourite (path, name, size, added) VALUES (?, ?, ?, ?)"
                : "DELETE FROM favourite WHERE path = ? AND size = ?", into: &statement)

            let now = Date().timeIntervalSince1970
            for item in items {
                sqlite3_reset(statement)
                bind(statement, 1, item.path)
                if on {
                    bind(statement, 2, item.name)
                    sqlite3_bind_int64(statement, 3, item.size)
                    sqlite3_bind_double(statement, 4, now)
                } else {
                    sqlite3_bind_int64(statement, 2, item.size)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }

                let identity = SyncIdentity.favourite(path: item.path, size: item.size)
                try journal(on ? .save : .delete, identity, payload: on
                    ? .favourite(path: item.path, name: item.name, size: item.size,
                                 added: now, modified: now)
                    : nil)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func favourites() throws -> [Item] {
        try open()
        return try collect("SELECT path, name, size FROM favourite ORDER BY added DESC")
    }

    // MARK: Notes

    /// Writes a note, or removes it when the text comes back empty — an emptied note is a
    /// deleted note, not a row holding an empty string that search would match on.
    func setNote(_ body: String, on item: Item) throws {
        try open()
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = SyncIdentity.note(path: item.path, size: item.size)
        let now = Date().timeIntervalSince1970

        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            if text.isEmpty {
                try prepare("DELETE FROM note WHERE path = ? AND size = ?", into: &statement)
                bind(statement, 1, item.path)
                sqlite3_bind_int64(statement, 2, item.size)
            } else {
                try prepare("""
                    INSERT INTO note (path, name, size, body, modified) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(path, size) DO UPDATE SET name = excluded.name,
                        body = excluded.body, modified = excluded.modified
                    """, into: &statement)
                bind(statement, 1, item.path)
                bind(statement, 2, item.name)
                sqlite3_bind_int64(statement, 3, item.size)
                bind(statement, 4, text)
                sqlite3_bind_double(statement, 5, now)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }

            try journal(text.isEmpty ? .delete : .save, identity,
                        payload: text.isEmpty ? nil
                            : .note(path: item.path, name: item.name, size: item.size,
                                    body: text, modified: now))
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func note(on item: Item) throws -> String? {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT body FROM note WHERE path = ? AND size = ?", into: &statement)
        bind(statement, 1, item.path)
        sqlite3_bind_int64(statement, 2, item.size)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    /// One query for a whole screenful, so a grid can mark annotated items without asking
    /// once per cell.
    func notedPaths() throws -> Set<String> {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path FROM note", into: &statement)
        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { paths.insert(String(cString: raw)) }
        }
        return paths
    }

    func noteCount() throws -> Int {
        try open()
        return Int(try scalar("SELECT count(*) FROM note") ?? 0)
    }

    /// Paths that belong to at least one collection, for the grid's badges — one query for
    /// a screenful rather than one per cell, the same shape as `notedPaths`.
    func collectedPaths() throws -> Set<String> {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT DISTINCT path FROM collection_item", into: &statement)
        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { paths.insert(String(cString: raw)) }
        }
        return paths
    }

    func favouriteCount() throws -> Int {
        try open()
        return Int(try scalar("SELECT count(*) FROM favourite") ?? 0)
    }

    func isShortcut(_ folder: Item) throws -> Bool {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM shortcut WHERE path = ?", into: &statement)
        bind(statement, 1, folder.path)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func setShortcut(_ folder: Item, _ on: Bool) throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            if on {
                try prepare("INSERT OR IGNORE INTO shortcut (path, name, added) VALUES (?, ?, ?)",
                            into: &statement)
                bind(statement, 1, folder.path)
                bind(statement, 2, folder.name)
                sqlite3_bind_double(statement, 3, now)
            } else {
                try prepare("DELETE FROM shortcut WHERE path = ?", into: &statement)
                bind(statement, 1, folder.path)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }

            try journal(on ? .save : .delete, .shortcut(path: folder.path), payload: on
                ? .shortcut(path: folder.path, name: folder.name, added: now, modified: now)
                : nil)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func shortcuts() throws -> [Item] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, name FROM shortcut ORDER BY added DESC", into: &statement)

        var folders: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            folders.append(Item(path: String(cString: path), name: String(cString: name),
                                isDirectory: true, size: 0, modified: nil, mimeType: nil))
        }
        return folders
    }

    func collections() throws -> [Collection] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT c.id, c.name, (SELECT count(*) FROM collection_item i "
                + "WHERE i.collection_id = c.id) FROM collection c "
                + "ORDER BY c.name COLLATE NOCASE"
        try prepare(sql, into: &statement)

        var found: [Collection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            found.append(Collection(id: sqlite3_column_int64(statement, 0),
                                    name: String(cString: name),
                                    count: Int(sqlite3_column_int64(statement, 2))))
        }
        return found
    }

    /// Returns the existing collection when the name is taken rather than failing: two
    /// collections with the same name would be impossible to tell apart.
    @discardableResult
    func createCollection(named name: String) throws -> Int64 {
        try open()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.write("nom vide") }

        let id: Int64
        try exec("BEGIN IMMEDIATE")
        do {
            var insert: OpaquePointer?
            defer { sqlite3_finalize(insert) }
            try prepare("INSERT OR IGNORE INTO collection (name, created) VALUES (?, ?)",
                        into: &insert)
            bind(insert, 1, trimmed)
            sqlite3_bind_double(insert, 2, Date().timeIntervalSince1970)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.write(message) }

            var lookup: OpaquePointer?
            defer { sqlite3_finalize(lookup) }
            try prepare("SELECT id, created FROM collection WHERE name = ?", into: &lookup)
            bind(lookup, 1, trimmed)
            guard sqlite3_step(lookup) == SQLITE_ROW else { throw Failure.write(message) }
            id = sqlite3_column_int64(lookup, 0)
            let created = sqlite3_column_double(lookup, 1)

            // Journalled even when the name already existed: the save is idempotent, and the
            // device that lost the created-date tie simply adopts the other's.
            try journal(.save, .collection(name: trimmed),
                        payload: .collection(name: trimmed, created: created,
                                             modified: Date().timeIntervalSince1970))
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
        return id
    }

    /// A collection's sync identity is its name, so a rename is a delete of the old identity
    /// plus a save of the new — members included, since their record names embed the name.
    func renameCollection(_ id: Int64, to name: String) throws {
        try open()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let old = try collectionRow(id), old.name != trimmed else { return }

        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("UPDATE collection SET name = ? WHERE id = ?", into: &statement)
            bind(statement, 1, trimmed)
            sqlite3_bind_int64(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }

            let now = Date().timeIntervalSince1970
            try journal(.delete, .collection(name: old.name), payload: nil)
            try journal(.save, .collection(name: trimmed),
                        payload: .collection(name: trimmed, created: old.created, modified: now))
            for member in try memberRows(of: id) {
                try journal(.delete, .member(collection: old.name, path: member.path,
                                             size: member.size), payload: nil)
                try journal(.save, .member(collection: trimmed, path: member.path,
                                           size: member.size),
                            payload: .member(collection: trimmed, path: member.path,
                                             name: member.name, size: member.size,
                                             added: member.added, modified: now))
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func deleteCollection(_ id: Int64) throws {
        try open()
        guard let row = try collectionRow(id) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            // The members' tombstones must be written before the cascade erases them.
            for member in try memberRows(of: id) {
                try journal(.delete, .member(collection: row.name, path: member.path,
                                             size: member.size), payload: nil)
            }
            try journal(.delete, .collection(name: row.name), payload: nil)
            try exec("DELETE FROM collection WHERE id = \(id)")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func setMembership(_ items: [Item], in collectionID: Int64, _ on: Bool) throws {
        try open()
        guard let owner = try collectionRow(collectionID) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let insert = "INSERT OR IGNORE INTO collection_item "
                       + "(collection_id, path, name, size, added) VALUES (?, ?, ?, ?, ?)"
            let remove = "DELETE FROM collection_item "
                       + "WHERE collection_id = ? AND path = ? AND size = ?"
            try prepare(on ? insert : remove, into: &statement)

            let now = Date().timeIntervalSince1970
            for item in items {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, collectionID)
                bind(statement, 2, item.path)
                if on {
                    bind(statement, 3, item.name)
                    sqlite3_bind_int64(statement, 4, item.size)
                    sqlite3_bind_double(statement, 5, now)
                } else {
                    sqlite3_bind_int64(statement, 3, item.size)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }

                let identity = SyncIdentity.member(collection: owner.name, path: item.path,
                                                   size: item.size)
                try journal(on ? .save : .delete, identity, payload: on
                    ? .member(collection: owner.name, path: item.path, name: item.name,
                              size: item.size, added: now, modified: now)
                    : nil)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    func items(in collectionID: Int64) throws -> [Item] {
        try open()
        return try collect("SELECT path, name, size FROM collection_item "
                         + "WHERE collection_id = \(collectionID) ORDER BY added DESC")
    }

    func collectionsContaining(_ item: Item) throws -> Set<Int64> {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT collection_id FROM collection_item WHERE path = ? AND size = ?",
                    into: &statement)
        bind(statement, 1, item.path)
        sqlite3_bind_int64(statement, 2, item.size)

        var found: Set<Int64> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.insert(sqlite3_column_int64(statement, 0))
        }
        return found
    }

    /// Rebuilds items from a saved list, pulling in the capture date the index already knows
    /// so a collection sorts and groups like any other folder.
    private func collect(_ sql: String) throws -> [Item] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, into: &statement)

        var rows: [(path: String, name: String, size: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: path), String(cString: name),
                         sqlite3_column_int64(statement, 2)))
        }

        var dates: OpaquePointer?
        defer { sqlite3_finalize(dates) }
        let lookup = "SELECT fi.capture FROM file fi JOIN folder d ON d.id = fi.folder_id "
                   + "WHERE d.path = ? AND fi.name = ? AND fi.size = ?"
        try prepare(lookup, into: &dates)

        return rows.map { row in
            var capture: Date?
            sqlite3_reset(dates)
            bind(dates, 1, (row.path as NSString).deletingLastPathComponent)
            bind(dates, 2, row.name)
            sqlite3_bind_int64(dates, 3, row.size)
            if sqlite3_step(dates) == SQLITE_ROW, sqlite3_column_type(dates, 0) != SQLITE_NULL {
                capture = Date(timeIntervalSince1970: sqlite3_column_double(dates, 0))
            }
            return Item(path: row.path, name: row.name, isDirectory: false, size: row.size,
                        modified: nil, mimeType: nil, captureDate: capture)
        }
    }

    // MARK: Sync journal

    /// Everything here exists for the iCloud mirror. SQLite stays the source of truth: these
    /// methods record what must be pushed and apply what was fetched, nothing more.

    struct SyncChange: Equatable, Sendable {
        enum Op: Int64 { case save = 0, delete = 1 }
        let recordName: String
        let op: Op
        let payload: String?
        let changed: Double
        let server: Data?
    }

    private var onJournal: (@Sendable () -> Void)?

    /// The sync engine registers here to learn the journal grew. One observer is enough;
    /// nothing else has any business knowing.
    func setJournalObserver(_ observer: (@Sendable () -> Void)?) {
        onJournal = observer
    }

    private func notifyJournal() { onJournal?() }

    /// Written in the same transaction as the change it mirrors, so a kill can never lose a
    /// change nor invent one. One row per record: a re-toggle collapses onto itself.
    private func journal(_ op: SyncChange.Op, _ identity: SyncIdentity,
                         payload: SyncPayload?) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            INSERT INTO sync_pending (record_name, op, payload, changed, server)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(record_name) DO UPDATE SET op = excluded.op, payload = excluded.payload,
                changed = excluded.changed, server = excluded.server
            """, into: &statement)
        bind(statement, 1, identity.recordName)
        sqlite3_bind_int64(statement, 2, op.rawValue)
        if let payload {
            bind(statement, 3, try payload.encoded())
            sqlite3_bind_double(statement, 4, payload.modified)
        } else {
            sqlite3_bind_null(statement, 3)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    func pendingSyncChanges() throws -> [SyncChange] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT record_name, op, payload, changed, server FROM sync_pending",
                    into: &statement)
        var changes: [SyncChange] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let op = SyncChange.Op(rawValue: sqlite3_column_int64(statement, 1))
            else { continue }
            changes.append(SyncChange(
                recordName: String(cString: raw),
                op: op,
                payload: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                changed: sqlite3_column_double(statement, 3),
                server: sqlite3_column_blob(statement, 4).map {
                    Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 4)))
                }
            ))
        }
        return changes
    }

    /// One row by key — the engine asks for records one by one while building a batch, and a
    /// full-table read per record would turn the first upload into an O(n²) stall.
    func pendingSyncChange(recordName: String) throws -> SyncChange? {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT op, payload, changed, server FROM sync_pending WHERE record_name = ?",
                    into: &statement)
        bind(statement, 1, recordName)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let op = SyncChange.Op(rawValue: sqlite3_column_int64(statement, 0))
        else { return nil }
        return SyncChange(
            recordName: recordName,
            op: op,
            payload: sqlite3_column_text(statement, 1).map { String(cString: $0) },
            changed: sqlite3_column_double(statement, 2),
            server: sqlite3_column_blob(statement, 3).map {
                Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 3)))
            }
        )
    }

    /// Removes an acknowledged save — unless the row was rewritten during the round trip:
    /// a favourite re-toggled while the batch was in flight must still be sent.
    func clearSyncPendingSave(recordName: String, ifUnchangedSince stamp: Double) throws {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("DELETE FROM sync_pending WHERE record_name = ? AND op = 0 AND changed <= ?",
                    into: &statement)
        bind(statement, 1, recordName)
        sqlite3_bind_double(statement, 2, stamp)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    /// Removes an acknowledged delete. The guard here is the op itself, not a clock: if the
    /// user re-added the record meanwhile, the row flipped to a save and is kept.
    func clearSyncPendingDelete(recordName: String) throws {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("DELETE FROM sync_pending WHERE record_name = ? AND op = 1", into: &statement)
        bind(statement, 1, recordName)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    /// Stores the server's system fields after a save conflict, so the retry builds on the
    /// server's version instead of colliding with it a second time. `nil` clears a stale
    /// base — needed when the server record turns out to have been deleted meanwhile.
    func attachServerRecord(_ archive: Data?, to recordName: String) throws {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("UPDATE sync_pending SET server = ? WHERE record_name = ? AND op = 0",
                    into: &statement)
        if let archive {
            archive.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count),
                                      transientText)
            }
        } else {
            sqlite3_bind_null(statement, 1)
        }
        bind(statement, 2, recordName)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    /// Applies a batch fetched from CloudKit, without journalling any of it back — which is
    /// what prevents two devices from bouncing the same change for ever.
    ///
    /// Two deliberate asymmetries, both the assumed resurrection bias:
    /// - a remote delete is skipped while this device still holds an unpushed save of the
    ///   record — the save will go up and the record reappears everywhere;
    /// - a remote save cancels a pending local delete of the same record.
    /// In the twisted cases a favourite reappears rather than disappears: one tap re-removes
    /// it, a silent loss is unrecoverable.
    func applyRemote(saves: [SyncPayload], deletes: [String]) throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            if !deletes.isEmpty { try applyRemoteDeletes(Set(deletes)) }
            // Collections first: a member may need its collection row from the same batch.
            for payload in saves where payload.kind == "collection" {
                try applyRemoteSave(payload)
            }
            for payload in saves where payload.kind != "collection" {
                try applyRemoteSave(payload)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A remote delete only carries the record name — a hash. The rows are found by hashing
    /// what is here: a linear pass, fine for a few thousand rows of personalisation.
    private func applyRemoteDeletes(_ names: Set<String>) throws {
        let keep = Set(try pendingSyncChanges().filter { $0.op == .save }.map(\.recordName))
        let doomed = names.subtracting(keep)
        guard !doomed.isEmpty else { return }

        for row in try favouriteRows()
        where doomed.contains(SyncIdentity.favourite(path: row.path, size: row.size).recordName) {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM favourite WHERE path = ? AND size = ?", into: &statement)
            bind(statement, 1, row.path)
            sqlite3_bind_int64(statement, 2, row.size)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
        }

        for row in try noteRows()
        where doomed.contains(SyncIdentity.note(path: row.path, size: row.size).recordName) {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM note WHERE path = ? AND size = ?", into: &statement)
            bind(statement, 1, row.path)
            sqlite3_bind_int64(statement, 2, row.size)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
        }

        for folder in try shortcutPaths()
        where doomed.contains(SyncIdentity.shortcut(path: folder).recordName) {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM shortcut WHERE path = ?", into: &statement)
            bind(statement, 1, folder)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
        }

        for collection in try collectionRows() {
            for member in try memberRows(of: collection.id)
            where doomed.contains(SyncIdentity.member(collection: collection.name,
                                                      path: member.path,
                                                      size: member.size).recordName) {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare("DELETE FROM collection_item WHERE collection_id = ? AND path = ? "
                          + "AND size = ?", into: &statement)
                sqlite3_bind_int64(statement, 1, collection.id)
                bind(statement, 2, member.path)
                sqlite3_bind_int64(statement, 3, member.size)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
            }
            if doomed.contains(SyncIdentity.collection(name: collection.name).recordName) {
                try exec("DELETE FROM collection WHERE id = \(collection.id)")
            }
        }
    }

    private func applyRemoteSave(_ payload: SyncPayload) throws {
        // A record forged or truncated on the way in is dropped, not half-applied.
        guard let identity = payload.identity else { return }

        // Resurrection bias: an incoming save beats a pending local delete.
        var cancel: OpaquePointer?
        defer { sqlite3_finalize(cancel) }
        try prepare("DELETE FROM sync_pending WHERE record_name = ? AND op = 1", into: &cancel)
        bind(cancel, 1, identity.recordName)
        guard sqlite3_step(cancel) == SQLITE_DONE else { throw Failure.write(message) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        switch identity {
        case .favourite(let path, let size):
            try prepare("INSERT OR IGNORE INTO favourite (path, name, size, added) "
                      + "VALUES (?, ?, ?, ?)", into: &statement)
            bind(statement, 1, path)
            bind(statement, 2, payload.name ?? (path as NSString).lastPathComponent)
            sqlite3_bind_int64(statement, 3, size)
            sqlite3_bind_double(statement, 4, payload.added ?? payload.modified)
        case .shortcut(let path):
            try prepare("INSERT OR IGNORE INTO shortcut (path, name, added) VALUES (?, ?, ?)",
                        into: &statement)
            bind(statement, 1, path)
            bind(statement, 2, payload.name ?? (path as NSString).lastPathComponent)
            sqlite3_bind_double(statement, 3, payload.added ?? payload.modified)
        case .note(let path, let size):
            // The only record here where last-writer-wins has real work to do: two devices
            // can hold *different text* for the same note. The guard rides in the statement
            // so an older edit arriving late cannot overwrite a newer one.
            try prepare("""
                INSERT INTO note (path, name, size, body, modified) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path, size) DO UPDATE SET name = excluded.name,
                    body = excluded.body, modified = excluded.modified
                    WHERE excluded.modified > note.modified
                """, into: &statement)
            bind(statement, 1, path)
            bind(statement, 2, payload.name ?? (path as NSString).lastPathComponent)
            sqlite3_bind_int64(statement, 3, size)
            bind(statement, 4, payload.body ?? "")
            sqlite3_bind_double(statement, 5, payload.modified)
        case .collection(let name):
            try prepare("INSERT OR IGNORE INTO collection (name, created) VALUES (?, ?)",
                        into: &statement)
            bind(statement, 1, name)
            sqlite3_bind_double(statement, 2, payload.created ?? payload.modified)
        case .member(let collection, let path, let size):
            // A member whose collection was deleted on another device recreates it: the
            // resurrection bias again — deletion versus addition resolves to the addition.
            guard let owner = try collectionID(named: collection,
                                               created: payload.modified) else { return }
            try prepare("INSERT OR IGNORE INTO collection_item "
                      + "(collection_id, path, name, size, added) VALUES (?, ?, ?, ?, ?)",
                        into: &statement)
            sqlite3_bind_int64(statement, 1, owner)
            bind(statement, 2, path)
            bind(statement, 3, payload.name ?? (path as NSString).lastPathComponent)
            sqlite3_bind_int64(statement, 4, size)
            sqlite3_bind_double(statement, 5, payload.added ?? payload.modified)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    /// First engine start on a device that already holds personalisation — the current user's
    /// case: every row is journalled once, so everything goes up. No duplicates on the other
    /// side, since record names are deterministic. `syncSeeded` makes it once ever.
    @discardableResult
    func seedSyncJournalIfNeeded() throws -> Bool {
        try open()
        guard (try value(forKey: "syncSeeded") ?? 0) == 0 else { return false }
        try exec("BEGIN IMMEDIATE")
        do {
            try journalAllRows()
            try setValue(1, forKey: "syncSeeded")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
        return true
    }

    /// The CloudKit zone was deleted or its keys reset: local data is the source of truth,
    /// so everything is queued to be pushed again.
    func journalAllPersonalisation() throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            try journalAllRows()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        notifyJournal()
    }

    /// Saves for every existing row. Deliberately never touches pending deletes: a tombstone
    /// is not a row, re-journalling must not resurrect what the user just removed.
    private func journalAllRows() throws {
        let now = Date().timeIntervalSince1970
        for row in try favouriteRows() {
            try journal(.save, .favourite(path: row.path, size: row.size),
                        payload: .favourite(path: row.path, name: row.name, size: row.size,
                                            added: row.added, modified: now))
        }
        for row in try noteRows() {
            // Its own `modified`, not `now`: re-journalling must not make a stale note look
            // newer than the same note edited elsewhere.
            try journal(.save, .note(path: row.path, size: row.size),
                        payload: .note(path: row.path, name: row.name, size: row.size,
                                       body: row.body, modified: row.modified))
        }
        for row in try shortcutRows() {
            try journal(.save, .shortcut(path: row.path),
                        payload: .shortcut(path: row.path, name: row.name, added: row.added,
                                           modified: now))
        }
        for collection in try collectionRows() {
            try journal(.save, .collection(name: collection.name),
                        payload: .collection(name: collection.name, created: collection.created,
                                             modified: now))
            for member in try memberRows(of: collection.id) {
                try journal(.save, .member(collection: collection.name, path: member.path,
                                           size: member.size),
                            payload: .member(collection: collection.name, path: member.path,
                                             name: member.name, size: member.size,
                                             added: member.added, modified: now))
            }
        }
    }

    /// Another person's iCloud account signed in: their data must never mix with the previous
    /// owner's. Everything personal goes; the index stays — it is rebuildable, not personal.
    func wipePersonalisation() throws {
        try open()
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM collection")
            try exec("DELETE FROM favourite")
            try exec("DELETE FROM shortcut")
            try exec("DELETE FROM sync_pending")
            // Nothing old is left to seed, and the new account's data has yet to arrive.
            try setValue(1, forKey: "syncSeeded")
            try setValue(0, forKey: "syncFetched")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Which iCloud account this database's personalisation belongs to.
    func syncAccountID() throws -> String? {
        try open()
        return try textValue(forKey: "syncAccount")
    }

    func setSyncAccountID(_ id: String) throws {
        try open()
        try setTextValue(id, forKey: "syncAccount")
    }

    /// Distinguishes "empty because nothing has arrived yet" from "empty because there is
    /// nothing": only a completed first fetch may claim the latter.
    func syncFetchedOnce() throws -> Bool {
        try open()
        return (try value(forKey: "syncFetched") ?? 0) == 1
    }

    func setSyncFetchedOnce() throws {
        try open()
        try setValue(1, forKey: "syncFetched")
    }

    func personalisationIsEmpty() throws -> Bool {
        try open()
        return try scalar("SELECT (SELECT count(*) FROM favourite) "
                        + "+ (SELECT count(*) FROM shortcut) "
                        + "+ (SELECT count(*) FROM collection)") == 0
    }

    // Row readers shared by the journal and the remote-delete scan.

    private func favouriteRows() throws -> [(path: String, name: String, size: Int64,
                                             added: Double)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, name, size, added FROM favourite", into: &statement)
        var rows: [(String, String, Int64, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: path), String(cString: name),
                         sqlite3_column_int64(statement, 2), sqlite3_column_double(statement, 3)))
        }
        return rows
    }

    private func noteRows() throws -> [(path: String, name: String, size: Int64,
                                       body: String, modified: Double)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, name, size, body, modified FROM note", into: &statement)
        var rows: [(String, String, Int64, String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1),
                  let body = sqlite3_column_text(statement, 3) else { continue }
            rows.append((String(cString: path), String(cString: name),
                         sqlite3_column_int64(statement, 2), String(cString: body),
                         sqlite3_column_double(statement, 4)))
        }
        return rows
    }

    private func shortcutRows() throws -> [(path: String, name: String, added: Double)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, name, added FROM shortcut", into: &statement)
        var rows: [(String, String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: path), String(cString: name),
                         sqlite3_column_double(statement, 2)))
        }
        return rows
    }

    private func shortcutPaths() throws -> [String] {
        try shortcutRows().map(\.path)
    }

    private func collectionRows() throws -> [(id: Int64, name: String, created: Double)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id, name, created FROM collection", into: &statement)
        var rows: [(Int64, String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            rows.append((sqlite3_column_int64(statement, 0), String(cString: name),
                         sqlite3_column_double(statement, 2)))
        }
        return rows
    }

    private func collectionRow(_ id: Int64) throws -> (name: String, created: Double)? {
        try collectionRows().first { $0.id == id }.map { ($0.name, $0.created) }
    }

    private func memberRows(of collectionID: Int64) throws -> [(path: String, name: String,
                                                                size: Int64, added: Double)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, name, size, added FROM collection_item "
                  + "WHERE collection_id = ?", into: &statement)
        sqlite3_bind_int64(statement, 1, collectionID)
        var rows: [(String, String, Int64, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: path), String(cString: name),
                         sqlite3_column_int64(statement, 2), sqlite3_column_double(statement, 3)))
        }
        return rows
    }

    private func collectionID(named name: String, created: Double) throws -> Int64? {
        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        try prepare("INSERT OR IGNORE INTO collection (name, created) VALUES (?, ?)", into: &insert)
        bind(insert, 1, name)
        sqlite3_bind_double(insert, 2, created)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.write(message) }

        var lookup: OpaquePointer?
        defer { sqlite3_finalize(lookup) }
        try prepare("SELECT id FROM collection WHERE name = ?", into: &lookup)
        bind(lookup, 1, name)
        guard sqlite3_step(lookup) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(lookup, 0)
    }


    // MARK: Vanished items

    /// A saved item, checked against what the index actually saw on the NAS.
    struct Resolved: Sendable {
        /// Still there — possibly at a new path, if the file simply moved.
        let present: [Item]
        /// The folder was read end to end and this file was not in it. Gone, not merely unread.
        let missing: [Item]
    }

    /// Sorts saved favourites or collection members into what still exists and what does not.
    ///
    /// The distinction that matters: "not in the index" is not "deleted". A file whose folder
    /// has never been fully read is simply unknown, and accusing it of being gone would hide
    /// perfectly good photos. Only a file absent from a folder the index read end to end — one
    /// carrying a completion stamp — counts as missing.
    ///
    /// A file found elsewhere under the same name and size has moved, not vanished: its path is
    /// quietly updated. The sync identity is derived from name and size, so repathing causes no
    /// churn between devices.
    func resolve(_ items: [Item]) throws -> Resolved {
        try open()
        guard !items.isEmpty else { return Resolved(present: [], missing: []) }

        var present: [Item] = []
        var missing: [Item] = []

        for item in items {
            let parent = (item.path as NSString).deletingLastPathComponent
            guard let folder = try folderID(parent, create: false), try isStamped(folder) else {
                present.append(item)      // never fully read: no verdict
                continue
            }
            if try fileExists(in: folder, name: item.name, size: item.size) {
                present.append(item)
                continue
            }
            if let moved = try locate(name: item.name, size: item.size), moved != parent {
                let repathed = Item(path: moved + "/" + item.name, name: item.name,
                                    isDirectory: false, size: item.size, modified: nil,
                                    mimeType: nil, captureDate: item.captureDate)
                try repath(from: item, to: repathed)
                present.append(repathed)
                continue
            }
            missing.append(item)
        }
        return Resolved(present: present, missing: missing)
    }

    /// Same question for a pinned folder: does the index still know it?
    func resolveFolders(_ folders: [Item]) throws -> Resolved {
        try open()
        var present: [Item] = []
        var missing: [Item] = []

        for folder in folders {
            if try folderID(folder.path, create: false) != nil {
                present.append(folder)
                continue
            }
            let parent = (folder.path as NSString).deletingLastPathComponent
            guard let parentID = try folderID(parent, create: false), try isStamped(parentID) else {
                present.append(folder)    // parent never read: no verdict
                continue
            }
            missing.append(folder)
        }
        return Resolved(present: present, missing: missing)
    }

    private func isStamped(_ folder: Int64) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT mtime FROM folder WHERE id = ?", into: &statement)
        sqlite3_bind_int64(statement, 1, folder)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_type(statement, 0) != SQLITE_NULL
    }

    private func fileExists(in folder: Int64, name: String, size: Int64) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT 1 FROM file WHERE folder_id = ? AND name = ? AND size = ?",
                    into: &statement)
        sqlite3_bind_int64(statement, 1, folder)
        bind(statement, 2, name)
        sqlite3_bind_int64(statement, 3, size)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The folder holding this exact file, when there is exactly one. Several matches are an
    /// ambiguity we refuse to guess at, same doctrine as date adoption.
    private func locate(name: String, size: Int64) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT d.path FROM file fi JOIN folder d ON d.id = fi.folder_id "
                + "WHERE fi.name = ? AND fi.size = ? LIMIT 2"
        try prepare(sql, into: &statement)
        bind(statement, 1, name)
        sqlite3_bind_int64(statement, 2, size)

        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0) else { continue }
            found.append(String(cString: path))
        }
        return found.count == 1 ? found[0] : nil
    }

    private func repath(from old: Item, to new: Item) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for table in ["favourite", "collection_item"] {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare("UPDATE OR IGNORE \(table) SET path = ? WHERE path = ? AND size = ?",
                            into: &statement)
                bind(statement, 1, new.path)
                bind(statement, 2, old.path)
                sqlite3_bind_int64(statement, 3, old.size)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }


    // MARK: Live Photos

    /// Marks the `.MOV` half of every Live Photo in one folder.
    ///
    /// Runs once the folder's listing is complete, because the question "is there a still of
    /// the same stem next to it" can only be answered on the whole folder. A lone `.MOV`
    /// stays unmarked and visible: that is every video not shot on an iPhone.
    func markLivePairs(in folder: String) throws {
        try open()
        guard let id = try folderID(folder, create: false) else { return }
        try exec(Self.pairingSQL + " WHERE folder_id = \(id)")
    }

    /// The video that belongs to this still, when the index knows of one.
    func companion(of still: Item, in folder: String) throws -> Item? {
        try open()
        guard let id = try folderID(folder, create: false) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT name, size, capture FROM file
            WHERE folder_id = ? AND live = 1 AND stem(name) = stem(?)
            LIMIT 1
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, id)
        bind(statement, 2, still.name)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        let name = String(cString: raw)
        let capture = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return Item(path: folder + "/" + name, name: name, isDirectory: false,
                    size: sqlite3_column_int64(statement, 1), modified: nil,
                    mimeType: Item.Kind.video.mimeHint, captureDate: capture)
    }

    /// The one spelling of the rule on the SQL side, so it cannot drift from `LivePhotos`.
    ///
    /// Two refusals, mirroring `LivePhotos.compatible`. A contradiction — both halves read,
    /// both carrying an identifier, and the two differing. And a one-sided carrier whose
    /// capture dates disagree: an identifier on one half only means either a re-encode
    /// stripped the other half's (genuine pair, dates agree) or the true partner is elsewhere
    /// (dates disagree). A missing date keeps the pair, same as in Swift.
    private static let pairingSQL = """
        UPDATE file SET live = CASE WHEN kind = \(Item.Kind.video.code) AND EXISTS (
            SELECT 1 FROM file still WHERE still.folder_id = file.folder_id
              AND still.kind = \(Item.Kind.image.code)
              AND stem(still.name) = stem(file.name)
              AND NOT (still.cid IS NOT NULL AND still.cid <> ''
                       AND file.cid IS NOT NULL AND file.cid <> ''
                       AND still.cid <> file.cid)
              AND NOT (still.cid IS NOT NULL AND file.cid IS NOT NULL
                       AND ((still.cid = '' AND file.cid <> '')
                            OR (still.cid <> '' AND file.cid = ''))
                       AND still.capture IS NOT NULL AND file.capture IS NOT NULL
                       AND abs(still.capture - file.capture)
                           > \(Int(LivePhotos.captureTolerance)))
        ) THEN 1 ELSE 0 END
        """

    /// Re-queues the two halves of every name-paired moment whose verdict is still name-only.
    ///
    /// Follows `readerVersion` and not `liveVersion`: that one promises no network, and this
    /// costs reads. But only candidates — the still at its 24 KB prefix, the video at two or
    /// three ranged reads. A folder of 14 595 photos pays for its pairs, not its photos.
    ///
    /// Version 2: the one-sided pairs — exactly one half carrying an identifier — are now
    /// decided by their capture dates, and the video half was recorded blind before its date
    /// mattered. Re-read just those; the date comes from the same `moov` as the identifier.
    private static let identityVersion: Int64 = 2

    private func readIdentitiesAfterRuleChange() {
        guard let seen = try? value(forKey: "identityVersion") ?? 0,
              seen < Self.identityVersion else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            if seen < 1 {
                try exec("""
                    UPDATE file SET read = 0 WHERE cid IS NULL AND (
                        live = 1
                        OR (kind = \(Item.Kind.image.code) AND EXISTS (
                            SELECT 1 FROM file v WHERE v.folder_id = file.folder_id
                              AND v.kind = \(Item.Kind.video.code)
                              AND stem(v.name) = stem(file.name)))
                    )
                    """)
            }
            try exec("""
                UPDATE file SET read = 0
                WHERE kind = \(Item.Kind.video.code) AND capture IS NULL
                  AND cid IS NOT NULL AND EXISTS (
                    SELECT 1 FROM file still WHERE still.folder_id = file.folder_id
                      AND still.kind = \(Item.Kind.image.code)
                      AND stem(still.name) = stem(file.name)
                      AND still.cid IS NOT NULL
                      AND ((still.cid = '' AND file.cid <> '')
                           OR (still.cid <> '' AND file.cid = '')))
                """)
            // Same move as the reader version: a folder holding something unread can no
            // longer claim to be complete, or the walk would skip it.
            try exec("""
                UPDATE folder SET mtime = NULL WHERE id IN
                (SELECT DISTINCT folder_id FROM file WHERE read = 0)
                """)
            try setValue(Self.identityVersion, forKey: "identityVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    /// Bumped when the pairing rule changes. Marks every folder already indexed in one pass —
    /// no listing, no network, nothing re-read from the NAS.
    private static let liveVersion: Int64 = 1

    private func markLivePairsEverywhere() {
        guard let seen = try? value(forKey: "liveVersion") ?? 0,
              seen < Self.liveVersion else { return }
        do {
            try exec("BEGIN IMMEDIATE")
            try exec(Self.pairingSQL)
            try setValue(Self.liveVersion, forKey: "liveVersion")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
        }
    }

    // MARK: Search

    /// A file's full path, rebuilt from its folder row. Spelled once: it appears in every
    /// personalisation join below and a typo in one of them is a silently empty filter.
    private static let filePath = "d.path || '/' || fi.name"

    /// The six columns `items(from:)` expects, spelled once: every query that returns files
    /// reads them positionally, so a reordered `SELECT` elsewhere would silently swap a size
    /// for a date.
    private static let fileColumns =
        "SELECT d.path, fi.name, fi.size, fi.capture, fi.kind, fi.cid "
        + "FROM file fi JOIN folder d ON d.id = fi.folder_id"

    private func items(from statement: OpaquePointer?) -> [Item] {
        var found: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let folder = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            let capture = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            var item = Item(path: String(cString: folder) + "/" + String(cString: name),
                            name: String(cString: name), isDirectory: false,
                            size: sqlite3_column_int64(statement, 2), modified: nil,
                            mimeType: Item.Kind(code: Int(sqlite3_column_int64(statement, 4)))?
                                .mimeHint,
                            captureDate: capture)
            // The identifier travels with every index-sourced item, so the pairing rule sees
            // the same evidence whether the items came from a listing, a search or a probe.
            if let raw = sqlite3_column_text(statement, 5) { item.contentID = String(cString: raw) }
            found.append(item)
        }
        return found
    }

    /// Searches the index, never the box: instant, and it works with the NAS switched off.
    ///
    /// The trade-off to be honest about — only indexed folders can be found. A folder never
    /// walked is invisible here, which is why the UI says so rather than showing an empty list.
    func search(_ query: SearchQuery, limit: Int = 500) throws -> [Item] {
        try open()
        guard !query.isEmpty else { return [] }

        var conditions: [String] = []
        // The note counts as part of the item's text: writing "facture EDF" on a photo is
        // the only way to find it again, since its name is IMG_4821.
        if !query.text.trimmingCharacters(in: .whitespaces).isEmpty {
            conditions.append("(fold(fi.name) LIKE ?1 ESCAPE '\\' "
                            + "OR fold(d.path) LIKE ?1 ESCAPE '\\' "
                            + "OR EXISTS (SELECT 1 FROM note n WHERE n.path = \(Self.filePath) "
                            + "AND n.size = fi.size AND fold(n.body) LIKE ?1 ESCAPE '\\'))")
        }
        conditions.append("fi.kind IN (\(query.kinds.codes.map(String.init).joined(separator: ", ")))")
        // The hidden half of a Live Photo is not a result: it has the same name as its still
        // and would double every match.
        conditions.append("fi.live = 0")
        if query.favouritesOnly {
            conditions.append("EXISTS (SELECT 1 FROM favourite f "
                            + "WHERE f.path = \(Self.filePath) AND f.size = fi.size)")
        }
        if query.notedOnly {
            conditions.append("EXISTS (SELECT 1 FROM note n "
                            + "WHERE n.path = \(Self.filePath) AND n.size = fi.size)")
        }
        // A document has no capture date; a period narrows to what was actually shot.
        let window = query.period.range()
        if window != nil {
            conditions.append("fi.capture IS NOT NULL AND fi.capture BETWEEN ?2 AND ?3")
        }

        let sql = Self.fileColumns
                + " WHERE " + conditions.joined(separator: " AND ")
                + " ORDER BY fi.capture IS NULL, fi.capture DESC, fi.name LIMIT \(limit)"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, into: &statement)
        if !query.text.trimmingCharacters(in: .whitespaces).isEmpty {
            bind(statement, 1, SearchQuery.pattern(for: query.text))
        }
        if let window {
            sqlite3_bind_double(statement, 2, window.lowerBound)
            sqlite3_bind_double(statement, 3, window.upperBound)
        }

        return try matchingFolders(query) + items(from: statement)
    }

    /// Folders whose own name matches. Deliberately the name and not the whole path: searching
    /// `Photos` should not return the two hundred folders that merely live under `/Photos`.
    /// Skipped entirely when a media filter is on — a folder has no type and no capture date.
    private func matchingFolders(_ query: SearchQuery, limit: Int = 100) throws -> [Item] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, query.kinds == .everything, !query.favouritesOnly,
              !query.notedOnly, !query.period.isSet else { return [] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, child_count, "
                  + "EXISTS (SELECT 1 FROM note n WHERE n.path = folder.path "
                  + "AND fold(n.body) LIKE ?1 ESCAPE '\\') AS noted FROM folder "
                  + "WHERE fold(path) LIKE ?1 ESCAPE '\\' OR noted "
                  + "ORDER BY path LIMIT ?2", into: &statement)
        bind(statement, 1, SearchQuery.pattern(for: text))
        sqlite3_bind_int64(statement, 2, Int64(limit) * 4)

        let needle = SearchQuery.fold(text)
        var found: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW, found.count < limit {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let path = String(cString: raw)
            let name = String(path.split(separator: "/").last ?? "")
            // The SQL prefilter matches anywhere in the path; only the folder's own name —
            // or its note — should actually bring it back.
            let noted = sqlite3_column_int64(statement, 2) == 1
            guard noted || SearchQuery.fold(name).contains(needle) else { continue }
            let children = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 1))
            found.append(Item(path: path, name: name, isDirectory: true, size: 0,
                              modified: nil, mimeType: nil, childCount: children))
        }
        return found
    }

    /// Years the index actually knows about, newest first — the menu offers nothing empty.
    func indexedYears() throws -> [Int] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT DISTINCT CAST(strftime('%Y', capture, 'unixepoch') AS INTEGER) "
                  + "FROM file WHERE capture IS NOT NULL AND live = 0 ORDER BY 1 DESC",
                into: &statement)

        var years: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            years.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return years
    }

    #if DEBUG
    /// The folder with the most indexed media — what `ReadBench` should be pointed at, so the
    /// measurement is not dominated by the cost of listing a folder of twelve files.
    func largestFolder() throws -> (path: String, count: Int)? {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT path, media_count FROM folder WHERE media_count IS NOT NULL "
                  + "ORDER BY media_count DESC LIMIT 1", into: &statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return (String(cString: raw), Int(sqlite3_column_int64(statement, 1)))
    }

    /// Every pair the name rule keeps where exactly one half carries an identifier — the
    /// population the date rule arbitrates. For `ReadBench.oneSided`, which predicts the
    /// verdicts on the real library before the requeued reads make them permanent.
    func oneSidedPairs() throws -> [(folder: String, still: Item, video: Item)] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT d.path, s.name, s.size, s.capture, s.cid, v.name, v.size, v.capture, v.cid
            FROM file v
            JOIN folder d ON d.id = v.folder_id
            JOIN file s ON s.folder_id = v.folder_id AND s.kind = \(Item.Kind.image.code)
                       AND stem(s.name) = stem(v.name)
            WHERE v.kind = \(Item.Kind.video.code)
              AND v.cid IS NOT NULL AND s.cid IS NOT NULL
              AND ((s.cid = '' AND v.cid <> '') OR (s.cid <> '' AND v.cid = ''))
            ORDER BY d.path, v.name
            """, into: &statement)

        var pairs: [(String, Item, Item)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawFolder = sqlite3_column_text(statement, 0),
                  let rawStill = sqlite3_column_text(statement, 1),
                  let rawVideo = sqlite3_column_text(statement, 5) else { continue }
            let folder = String(cString: rawFolder)
            func capture(_ column: Int32) -> Date? {
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
            }
            var still = Item(path: folder + "/" + String(cString: rawStill),
                             name: String(cString: rawStill), isDirectory: false,
                             size: sqlite3_column_int64(statement, 2), modified: nil,
                             mimeType: Item.Kind.image.mimeHint, captureDate: capture(3))
            still.contentID = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            var video = Item(path: folder + "/" + String(cString: rawVideo),
                             name: String(cString: rawVideo), isDirectory: false,
                             size: sqlite3_column_int64(statement, 6), modified: nil,
                             mimeType: Item.Kind.video.mimeHint, captureDate: capture(7))
            video.contentID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            pairs.append((folder, still, video))
        }
        return pairs
    }
    #endif

    /// Folders the index has read end to end — what search can actually see.
    func indexedFolderCount() throws -> Int {
        try open()
        return Int(try scalar("SELECT count(*) FROM folder WHERE mtime IS NOT NULL") ?? 0)
    }

    // MARK: Migration

    /// A first index already paid for must not be paid for twice.
    private func migrateFromJSON(in folder: URL) {
        let dates = folder.appendingPathComponent("capture-dates.json")
        let walked = folder.appendingPathComponent("indexed-folders.json")
        guard FileManager.default.fileExists(atPath: dates.path) else { return }

        let records = (try? Data(contentsOf: dates))
            .flatMap { try? JSONDecoder().decode([String: Double?].self, from: $0) } ?? [:]
        let folders = (try? Data(contentsOf: walked))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]

        do {
            try exec("BEGIN IMMEDIATE")
            var statement: OpaquePointer?
            // In the old format, having an entry meant "read" — nothing else was stored.
            try prepare("""
                INSERT OR IGNORE INTO file (folder_id, name, size, capture, read, kind, gen)
                VALUES (?, ?, ?, ?, 1, ?, 0)
                """, into: &statement)

            var ids: [String: Int64] = [:]
            for (key, capture) in records {
                // "/a/b/photo.jpg|2048576"
                guard let bar = key.lastIndex(of: "|"),
                      let size = Int64(key[key.index(after: bar)...]) else { continue }
                let path = String(key[..<bar])
                let directory = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent

                let id: Int64
                if let cached = ids[directory] {
                    id = cached
                } else {
                    guard let made = try folderID(directory, create: true) else { continue }
                    ids[directory] = made
                    id = made
                }

                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, id)
                bind(statement, 2, name)
                sqlite3_bind_int64(statement, 3, size)
                if let capture = capture ?? nil {
                    sqlite3_bind_double(statement, 4, capture)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                let kind = Item(path: path, name: name, isDirectory: false, size: size,
                                modified: nil, mimeType: nil).kind
                sqlite3_bind_int64(statement, 5, Int64(kind.code))
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)

            for (path, mtime) in folders {
                guard let id = try folderID(path, create: true) else { continue }
                // Migrated folders keep their completion stamp; the tallies are unknown until
                // the next pass lists them again.
                try stampFolder(id, FolderStamp.Completion(
                    modified: Date(timeIntervalSince1970: mtime),
                    childCount: nil, mediaCount: nil, bytes: nil
                ))
            }
            try exec("COMMIT")

            try? FileManager.default.removeItem(at: dates)
            try? FileManager.default.removeItem(at: walked)
        } catch {
            try? exec("ROLLBACK")
        }
    }

    // MARK: Plumbing

    enum Failure: LocalizedError {
        case open(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .open(let detail): return "Index illisible : \(detail)"
            case .write(let detail): return "Écriture de l'index impossible : \(detail)"
            }
        }
    }

    private var message: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "inconnu"
    }

    /// Teaches SQLite to compare text the way a French speaker types it.
    ///
    /// `LIKE` only ignores case for ASCII, so `Été` would never answer to `ete`. Folding at
    /// query time costs a scan of the file table rather than an index seek — at a few hundred
    /// thousand rows that is still a few milliseconds, and it keeps the schema unchanged.
    // ponytail: full scan; add a stored folded column + index if the index ever outgrows it.
    private func registerFold() {
        let fold: @convention(c) (OpaquePointer?, Int32,
                                  UnsafeMutablePointer<OpaquePointer?>?) -> Void = { ctx, n, args in
            guard n == 1, let args, let raw = sqlite3_value_text(args[0]) else {
                sqlite3_result_null(ctx)
                return
            }
            sqlite3_result_text(ctx, SearchQuery.fold(String(cString: raw)), -1, transientText)
        }
        sqlite3_create_function_v2(db, "fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                   nil, fold, nil, nil, nil)
    }

    /// `stem('IMG_4821.MOV')` is `img_4821`, which is how the two halves of a Live Photo
    /// find each other. Same shape as `fold`, and the same reason: the rule must be one rule.
    private func registerStem() {
        let stem: @convention(c) (OpaquePointer?, Int32,
                                  UnsafeMutablePointer<OpaquePointer?>?) -> Void = { ctx, n, args in
            guard n == 1, let args, let raw = sqlite3_value_text(args[0]) else {
                sqlite3_result_null(ctx)
                return
            }
            sqlite3_result_text(ctx, LivePhotos.key(String(cString: raw)), -1, transientText)
        }
        sqlite3_create_function_v2(db, "stem", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                   nil, stem, nil, nil, nil)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.write(message) }
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.write(message)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transientText)
    }

    private func scalar(_ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, into: &statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func value(forKey key: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT v FROM meta WHERE k = ?", into: &statement)
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func textValue(forKey key: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT v FROM meta WHERE k = ?", into: &statement)
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func setTextValue(_ value: String, forKey key: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                    into: &statement)
        bind(statement, 1, key)
        bind(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    private func setValue(_ value: Int64, forKey key: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                    into: &statement)
        bind(statement, 1, key)
        sqlite3_bind_int64(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    private func folderID(_ path: String, create: Bool) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id FROM folder WHERE path = ?", into: &statement)
        bind(statement, 1, path)
        if sqlite3_step(statement) == SQLITE_ROW { return sqlite3_column_int64(statement, 0) }
        guard create else { return nil }

        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        try prepare("INSERT INTO folder (path) VALUES (?)", into: &insert)
        bind(insert, 1, path)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.write(message) }
        return sqlite3_last_insert_rowid(db)
    }

    private func stampFolder(_ id: Int64, _ completion: FolderStamp.Completion) throws {
        guard let stamp = FolderStamp.stamp(for: completion.modified) else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            UPDATE folder SET mtime = ?, child_count = ?, media_count = ?, bytes = ?
            WHERE id = ?
            """, into: &statement)
        sqlite3_bind_double(statement, 1, stamp)
        bindOptional(statement, 2, completion.childCount.map(Int64.init))
        bindOptional(statement, 3, completion.mediaCount.map(Int64.init))
        bindOptional(statement, 4, completion.bytes)
        sqlite3_bind_int64(statement, 5, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.write(message) }
    }

    private func bindOptional(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: Widget

    /// The photos the widget shows for a pinned folder, taken from its whole subtree.
    ///
    /// Ordered by kind first so photos come before videos: a video costs an
    /// `AVAssetImageGenerator` pass to produce one frame. Undated files sort last on their
    /// own — SQLite ranks NULL below everything, so `capture DESC` leaves them as filler for
    /// a folder the date reader has not reached yet, rather than as the headline.
    /// Named apart from `covers(for:)`, which answers "one tile image per folder" — same
    /// ordering, a different question, and two overloads of one name would read as the same.
    /// `kinds` restreint ce qui remonte. L'étagère de l'accueil s'appelle « Dernières
    /// photos » : elle ne doit donc montrer que des photos, pas des vidéos sous un titre qui
    /// n'est pas le leur. Le widget, lui, prend les deux.
    /// Ce qui est arrivé depuis que Keo regarde, tous genres confondus — documents compris.
    ///
    /// La jointure avec `arrival` fait le tri toute seule : ce qui a été indexé avant
    /// l'existence de la table n'y figure pas, et il vaut mieux une étagère qui se remplit au
    /// fil des jours qu'une étagère qui ment sur ses 23 000 premiers éléments.
    func recentlyAdded(under folder: String, limit: Int = 6) throws -> [Item] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let scope = "d.path = ?2 OR " + Self.subtree("d.path", low: 1, high: 4)
        try prepare("""
            SELECT d.path, fi.name, fi.size, fi.capture, fi.kind
            FROM file fi
            JOIN folder d ON d.id = fi.folder_id
            -- Une jointure, pas un LEFT JOIN : sans date d'arrivee notee, le fichier etait
            -- deja la avant que Keo ne compte, et il n'a rien a faire dans « Derniers ajouts ».
            JOIN arrival ar ON ar.folder_id = fi.folder_id
                           AND ar.name = fi.name AND ar.size = fi.size
            WHERE (\(scope)) AND fi.live = 0
            ORDER BY ar.added DESC, d.path, fi.name
            LIMIT ?3
            """, into: &statement)
        bindSubtree(statement, folder, low: 1, high: 4)
        bind(statement, 2, folder)
        sqlite3_bind_int64(statement, 3, Int64(limit))

        var found: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let rawFolder = sqlite3_column_text(statement, 0),
              let rawName = sqlite3_column_text(statement, 1) {
            let name = String(cString: rawName)
            let capture = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            found.append(Item(
                path: String(cString: rawFolder) + "/" + name,
                name: name,
                isDirectory: false,
                size: sqlite3_column_int64(statement, 2),
                modified: nil,
                mimeType: Item.Kind(code: Int(sqlite3_column_int64(statement, 4)))?.mimeHint,
                captureDate: capture
            ))
        }
        return found
    }

    func recentMedia(under folder: String, limit: Int = 12,
                     kinds: [Item.Kind] = [.image, .video]) throws -> [Item] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // The shared spelling, which also behaves at the root — see `subtree(_:)`.
        let scope = "d.path = ?2 OR " + Self.subtree("d.path", low: 1, high: 4)
        try prepare("""
            SELECT d.path, fi.name, fi.size, fi.capture, fi.kind
            FROM file fi JOIN folder d ON d.id = fi.folder_id
            WHERE (\(scope)) AND fi.live = 0
              AND fi.kind IN (\(kinds.map { String($0.code) }.joined(separator: ", ")))
            ORDER BY fi.kind, fi.capture DESC, d.path, fi.name
            LIMIT ?3
            """, into: &statement)
        bindSubtree(statement, folder, low: 1, high: 4)
        bind(statement, 2, folder)
        sqlite3_bind_int64(statement, 3, Int64(limit))

        var found: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let parent = sqlite3_column_text(statement, 0),
                  let raw = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: raw)
            let kind = Item.Kind(code: Int(sqlite3_column_int64(statement, 4)))
            let capture = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            found.append(Item(path: (String(cString: parent) as NSString)
                                .appendingPathComponent(name),
                              name: name, isDirectory: false,
                              size: sqlite3_column_int64(statement, 2),
                              modified: nil, mimeType: kind?.mimeHint,
                              captureDate: capture))
        }
        return found
    }

    /// The five scalars the coverage widget lives on.
    ///
    /// Not `homeSummary()`, which also scans for memories and year tallies: this one runs on
    /// every foreground pass, including the ones where the render is skipped entirely.
    func widgetCoverage() throws -> WidgetManifest.Coverage {
        try open()
        var coverage = WidgetManifest.Coverage()
        coverage.knownFolders = Int(try scalar("SELECT count(*) FROM folder") ?? 0)
        coverage.indexedFolders = Int(try scalar(
            "SELECT count(*) FROM folder WHERE mtime IS NOT NULL") ?? 0)
        coverage.unreadFiles = Int(try scalar("SELECT count(*) FROM file WHERE read = 0") ?? 0)
        // Same population as `datelessFiles()` lists, so the number on the Lock Screen and
        // the rows behind the tap cannot disagree.
        coverage.datelessFiles = Int(try scalar(
            "SELECT count(*) FROM file WHERE kind IN (1, 2) AND capture IS NULL "
          + "AND read = 1 AND live = 0")
            ?? 0)
        coverage.fileCount = Int(try scalar("SELECT count(*) FROM file") ?? 0)
        return coverage
    }

    /// Grants one widget render per interval, or straight away when the pinned set changed —
    /// a folder just pinned must not wait an hour for its first photos. Claiming writes the
    /// stamp, so two foregrounds in a row cannot both win it.
    func claimWidgetRender(signature: String, interval: TimeInterval) throws -> Bool {
        try open()
        let now = Date().timeIntervalSince1970
        let last = Double(try value(forKey: "widgetRenderedAt") ?? 0)
        if now - last < interval, try textValue(forKey: "widgetFolders") == signature {
            return false
        }
        try setValue(Int64(now), forKey: "widgetRenderedAt")
        try setTextValue(signature, forKey: "widgetFolders")
        return true
    }

    /// What a folder tile shows, summed over the folder and everything beneath it — a parent
    /// full of subfolders would otherwise claim to be empty.
    func stats(for folders: [String]) throws -> [String: FolderStats] {
        try open()
        guard !folders.isEmpty else { return [:] }

        let scope = "path = ?2 OR " + Self.subtree(low: 1, high: 3)

        var totals: OpaquePointer?
        defer { sqlite3_finalize(totals) }
        try prepare("SELECT sum(media_count), sum(bytes) FROM folder WHERE " + scope, into: &totals)

        var span: OpaquePointer?
        defer { sqlite3_finalize(span) }
        let spanSQL = "SELECT min(capture), max(capture) FROM file "
                    + "WHERE folder_id IN (SELECT id FROM folder WHERE " + scope + ")"
        try prepare(spanSQL, into: &span)

        var found: [String: FolderStats] = [:]
        for folder in folders {
            sqlite3_reset(totals)
            bindSubtree(totals, folder, low: 1, high: 3)
            bind(totals, 2, folder)
            guard sqlite3_step(totals) == SQLITE_ROW,
                  sqlite3_column_type(totals, 0) != SQLITE_NULL else { continue }
            let count = Int(sqlite3_column_int64(totals, 0))
            let bytes = sqlite3_column_type(totals, 1) == SQLITE_NULL
                ? nil : sqlite3_column_int64(totals, 1)

            sqlite3_reset(span)
            bindSubtree(span, folder, low: 1, high: 3)
            bind(span, 2, folder)
            var earliest: Date?
            var latest: Date?
            if sqlite3_step(span) == SQLITE_ROW, sqlite3_column_type(span, 0) != SQLITE_NULL {
                earliest = Date(timeIntervalSince1970: sqlite3_column_double(span, 0))
                latest = Date(timeIntervalSince1970: sqlite3_column_double(span, 1))
            }
            found[folder] = FolderStats(mediaCount: count, bytes: bytes,
                                        earliest: earliest, latest: latest)
        }
        return found
    }

    /// The photos to show on each folder card, taken from the subtree like the totals above.
    ///
    /// An image beats a video: decoding a video cover costs an AVFoundation session, a still
    /// costs the 256 KB probe the pipeline already does. Among images, the most recent capture
    /// says more about the folder than an arbitrary one. The trailing path and name make the
    /// order total, so the same folder never comes back with a different set.
    ///
    /// `limit` is how many the caller can show — one for a single cover, three for the fan in
    /// the corner of a card. They come back in order, best first.
    func covers(for folders: [String], limit: Int = 1) throws -> [String: [Item]] {
        try open()
        guard !folders.isEmpty else { return [:] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT folder.path, file.name, file.size, file.kind
            FROM file JOIN folder ON folder.id = file.folder_id
            WHERE file.kind IN (1, 2) AND file.live = 0
              AND (folder.path = ?2 OR \(Self.subtree("folder.path", low: 1, high: 3)))
            ORDER BY file.kind, file.capture DESC, folder.path, file.name
            LIMIT ?4
            """, into: &statement)

        var found: [String: [Item]] = [:]
        for folder in folders {
            sqlite3_reset(statement)
            bindSubtree(statement, folder, low: 1, high: 3)
            bind(statement, 2, folder)
            sqlite3_bind_int64(statement, 4, Int64(max(1, limit)))
            var picks: [Item] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let rawFolder = sqlite3_column_text(statement, 0),
                  let rawName = sqlite3_column_text(statement, 1) {
                let name = String(cString: rawName)
                picks.append(Item(
                    path: String(cString: rawFolder) + "/" + name,
                    name: name,
                    isDirectory: false,
                    size: sqlite3_column_int64(statement, 2),
                    modified: nil,
                    mimeType: Item.Kind(code: Int(sqlite3_column_int64(statement, 3)))?.mimeHint
                ))
            }
            if !picks.isEmpty { found[folder] = picks }
        }
        return found
    }

    // MARK: Statistics

    /// Everything the statistics screen shows, in a single hop onto the actor.
    ///
    /// A dozen full scans of `file`, deliberately: the table is `WITHOUT ROWID` and its
    /// primary key already carries the name, so a secondary index that would speed these up
    /// costs roughly another copy of the table on disk. The screen reads this once and keeps
    /// it for as long as it is open.
    /// Five questions, not the dozen `statistics` asks: this one runs on every launch.
    /// The box's capacity, read when the phone was last on the home network.
    ///
    /// Kept here rather than fetched on sight: Keo is LAN-only, so the gauge would be blank
    /// every time the owner is out — which is most of the day. The box does not sleep; the
    /// phone leaves.
    func rememberCapacity(total: Int64, free: Int64) throws {
        try open()
        try setValue(total, forKey: "diskTotal")
        try setValue(free, forKey: "diskFree")
        try setValue(Int64(Date().timeIntervalSince1970), forKey: "diskSeen")
    }

    func capacity() throws -> (total: Int64, free: Int64, seen: Date)? {
        try open()
        guard let total = try value(forKey: "diskTotal"), total > 0,
              let free = try value(forKey: "diskFree"),
              let seen = try value(forKey: "diskSeen") else { return nil }
        return (total, free, Date(timeIntervalSince1970: Double(seen)))
    }

    func homeSummary(on today: Date = Date()) throws -> HomeSummary {
        try open()
        var summary = HomeSummary()
        summary.memories = try memories(today, limit: 120)
        summary.years = try years()
        if let first = try scalar("SELECT CAST(min(capture) AS INTEGER) FROM file "
                                + "WHERE kind IN (1, 2) AND capture IS NOT NULL AND live = 0") {
            summary.firstCapture = Date(timeIntervalSince1970: Double(first))
        }
        summary.knownFolders = Int(try scalar("SELECT count(*) FROM folder") ?? 0)
        summary.indexedFolders = Int(try scalar(
            "SELECT count(*) FROM folder WHERE mtime IS NOT NULL") ?? 0)
        summary.unreadFiles = Int(try scalar("SELECT count(*) FROM file WHERE read = 0") ?? 0)
        summary.fileCount = Int(try scalar("SELECT count(*) FROM file") ?? 0)
        summary.bytes = try scalar("SELECT coalesce(sum(bytes), 0) FROM folder") ?? 0
        summary.unweighed = Int(try scalar(
            "SELECT count(*) FROM folder WHERE mtime IS NOT NULL AND bytes IS NULL") ?? 0)
        return summary
    }

    func statistics(under root: String, on today: Date = Date()) throws -> LibraryStats {
        try open()
        var stats = LibraryStats()

        stats.knownFolders = Int(try scalar("SELECT count(*) FROM folder") ?? 0)
        stats.indexedFolders = Int(try scalar(
            "SELECT count(*) FROM folder WHERE mtime IS NOT NULL") ?? 0)
        stats.unreadFiles = Int(try scalar("SELECT count(*) FROM file WHERE read = 0") ?? 0)

        stats.years = try years()
        (stats.datelessRead, stats.datelessUnread) = try datelessSplit()
        if let first = try scalar("SELECT CAST(min(capture) AS INTEGER) FROM file "
                                + "WHERE kind IN (1, 2) AND capture IS NOT NULL") {
            stats.firstCapture = Date(timeIntervalSince1970: Double(first))
        }
        stats.gap = Statistics.longestGap(try captureMonths())

        stats.kinds = try kindTallies()
        stats.subtrees = try heaviestSubtrees(under: root)

        stats.duplicates = try duplicateTotals()
        stats.worstDuplicates = try worstDuplicates()

        stats.biggest = try biggestFiles()
        stats.busiestDays = try busiestDays()
        stats.onThisDay = try memories(today, limit: 300)
        return stats
    }

    /// Local time, not UTC: a photo taken on 1 January at 00:30 belongs to the year the
    /// calendar showed, and that is the year a tap on the bar will filter on.
    private func years() throws -> [YearTally] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT CAST(strftime('%Y', capture, 'unixepoch', 'localtime') AS INTEGER) AS annee,
                   sum(kind = 1), sum(kind = 2)
            FROM file WHERE kind IN (1, 2) AND capture IS NOT NULL AND live = 0
            GROUP BY annee ORDER BY annee
            """, into: &statement)

        var tallies: [YearTally] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tallies.append(YearTally(year: Int(sqlite3_column_int64(statement, 0)),
                                     photos: Int(sqlite3_column_int64(statement, 1)),
                                     videos: Int(sqlite3_column_int64(statement, 2))))
        }
        return tallies
    }

    /// The two halves of "no date", which must never be added together: one says the file
    /// carries no date, the other says nobody has looked yet.
    ///
    /// `live = 0` here and in every capture aggregate below: a Live Photo's hidden video now
    /// carries its own date (the pairing rule needs it), but the moment is already counted
    /// through its still — and when the video has none, the *moment* is not dateless.
    private func datelessSplit() throws -> (read: Int, unread: Int) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT sum(read = 1), sum(read = 0) FROM file "
                  + "WHERE kind IN (1, 2) AND capture IS NULL AND live = 0", into: &statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    /// Every month holding at least one photo, encoded so the gap is plain arithmetic.
    private func captureMonths() throws -> [Int] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT DISTINCT CAST(strftime('%Y', capture, 'unixepoch', 'localtime') AS INTEGER) * 12
                          + CAST(strftime('%m', capture, 'unixepoch', 'localtime') AS INTEGER) - 1
            FROM file WHERE kind IN (1, 2) AND capture IS NOT NULL AND live = 0 ORDER BY 1
            """, into: &statement)

        var months: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            months.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return months
    }

    /// Sums `file.size`, everything a listing showed — unlike the subtree weights below,
    /// which sum `folder.bytes` and so only count folders read end to end. Both are honest
    /// and they do not reconcile to the byte; the screen says which is which.
    private func kindTallies() throws -> [KindTally] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT kind, count(*), coalesce(sum(size), 0) FROM file "
                  + "WHERE kind IN (1, 2, 3) GROUP BY kind ORDER BY kind", into: &statement)

        var tallies: [KindTally] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = Item.Kind(code: Int(sqlite3_column_int64(statement, 0)))
            else { continue }
            tallies.append(KindTally(kind: kind, count: Int(sqlite3_column_int64(statement, 1)),
                                     bytes: sqlite3_column_int64(statement, 2)))
        }
        return tallies
    }

    /// The heaviest direct children of `root`, each summed over its whole subtree.
    ///
    /// Grouped in SQL on the first path segment after the prefix: pulling every folder row
    /// back into Swift to split strings would be the same work done twice.
    func heaviestSubtrees(under root: String, limit: Int = 12) throws -> [Subtree] {
        try open()
        let prefix = Statistics.scopePrefix(root)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT enfant, coalesce(sum(bytes), 0), coalesce(sum(media_count), 0),
                   count(*), sum(bytes IS NULL)
            FROM (SELECT CASE WHEN instr(reste, '/') = 0 THEN reste
                              ELSE substr(reste, 1, instr(reste, '/') - 1) END AS enfant,
                         bytes, media_count
                  FROM (SELECT substr(path, length(?1) + 1) AS reste, bytes, media_count
                        FROM folder WHERE \(Self.subtree(low: 1, high: 3))))
            WHERE enfant <> ''
            GROUP BY enfant ORDER BY 2 DESC LIMIT ?2
            """, into: &statement)
        bind(statement, 1, prefix)
        sqlite3_bind_int64(statement, 2, Int64(limit))
        bind(statement, 3, Self.upperBound(prefix))

        var subtrees: [Subtree] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: raw)
            subtrees.append(Subtree(name: name, path: prefix + name,
                                    bytes: sqlite3_column_int64(statement, 1),
                                    media: Int(sqlite3_column_int64(statement, 2)),
                                    folders: Int(sqlite3_column_int64(statement, 3)),
                                    unweighed: Int(sqlite3_column_int64(statement, 4))))
        }
        return subtrees
    }

    /// Same name and same size, in several folders. Not a hash, and the screen never claims
    /// otherwise — two different shots can share a name and a byte count.
    func duplicateTotals() throws -> DuplicateTotals {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT count(*), coalesce(sum(copies - 1), 0),
                   coalesce(sum((copies - 1) * size), 0)
            FROM (SELECT size, count(*) AS copies FROM file GROUP BY name, size
                  HAVING copies > 1)
            """, into: &statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return DuplicateTotals() }
        return DuplicateTotals(groups: Int(sqlite3_column_int64(statement, 0)),
                               extraFiles: Int(sqlite3_column_int64(statement, 1)),
                               recoverableBytes: sqlite3_column_int64(statement, 2))
    }

    /// Ordered by what the copies actually cost, not by how many there are: forty copies of
    /// a thumbnail matter less than two copies of a 4 Go film.
    func worstDuplicates(limit: Int = 20) throws -> [DuplicateGroup] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT name, size, count(*) AS copies FROM file GROUP BY name, size
            HAVING copies > 1 ORDER BY (copies - 1) * size DESC, name LIMIT ?1
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, Int64(limit))

        var groups: [DuplicateGroup] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            groups.append(DuplicateGroup(name: String(cString: raw),
                                         size: sqlite3_column_int64(statement, 1),
                                         copies: Int(sqlite3_column_int64(statement, 2))))
        }
        return groups
    }

    /// Where the copies of one group sit, so the user can go and look before deciding
    /// anything — the app itself will never remove one.
    func copies(of group: DuplicateGroup) throws -> [Item] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(Self.fileColumns + " WHERE fi.name = ?1 AND fi.size = ?2 ORDER BY d.path",
                    into: &statement)
        bind(statement, 1, group.name)
        sqlite3_bind_int64(statement, 2, group.size)
        return items(from: statement)
    }

    /// The media that were read end to end and still carry no date — not the ones nobody has
    /// opened yet, which is a different sentence and a different list.
    func datelessFiles(limit: Int = 500) throws -> [Item] {
        try open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(Self.fileColumns + """
             WHERE fi.kind IN (1, 2) AND fi.capture IS NULL AND fi.read = 1 AND fi.live = 0
             ORDER BY d.path, fi.name LIMIT ?1
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, Int64(limit))
        return items(from: statement)
    }

    private func biggestFiles(limit: Int = 25) throws -> [Item] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // The trailing path and name make the order total: two files of the same size must
        // not swap places between two openings of the screen.
        try prepare(Self.fileColumns + " ORDER BY fi.size DESC, d.path, fi.name LIMIT ?1",
                    into: &statement)
        sqlite3_bind_int64(statement, 1, Int64(limit))
        return items(from: statement)
    }

    private func busiestDays(limit: Int = 15) throws -> [DayTally] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT date(capture, 'unixepoch', 'localtime') AS jour, count(*) FROM file
            WHERE kind IN (1, 2) AND capture IS NOT NULL AND live = 0
            GROUP BY jour ORDER BY 2 DESC, jour DESC LIMIT ?1
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, Int64(limit))

        var days: [DayTally] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let day = Statistics.day(String(cString: raw)) else { continue }
            days.append(DayTally(day: day, count: Int(sqlite3_column_int64(statement, 1))))
        }
        return days
    }

    /// The same calendar day in earlier years. Bounded by the start of today so this
    /// morning's own photos do not come back as a souvenir.
    ///
    /// Not private: the widget renderer wants the same list, and a second query that drifts
    /// from this one would put a different day on the Home Screen than in the app.
    func onThisDay(_ today: Date, limit: Int = 300) throws -> [Item] {
        try open()
        return try memories(today, limit: limit)
    }

    private func memories(_ today: Date, limit: Int) throws -> [Item] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(Self.fileColumns + """
             WHERE fi.kind IN (1, 2) AND fi.capture IS NOT NULL AND fi.live = 0
               AND fi.capture < ?2
               AND strftime('%m-%d', fi.capture, 'unixepoch', 'localtime') = ?1
             ORDER BY fi.capture DESC, d.path, fi.name LIMIT ?3
            """, into: &statement)
        bind(statement, 1, Statistics.monthDay(today))
        sqlite3_bind_double(statement, 2,
                            Calendar.current.startOfDay(for: today).timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, Int64(limit))
        return items(from: statement)
    }

}
