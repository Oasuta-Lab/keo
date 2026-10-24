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
        try exec(Self.schema)
        // Older databases predate the per-folder tallies; adding them is harmless if present.
        try? exec("ALTER TABLE folder ADD COLUMN media_count INTEGER")
        try? exec("ALTER TABLE folder ADD COLUMN bytes INTEGER")
        try? exec("ALTER TABLE file ADD COLUMN read INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE file ADD COLUMN kind INTEGER NOT NULL DEFAULT 3")
        // Rows written before the column existed were all read ones.
        try? exec("UPDATE file SET read = 1 WHERE read = 0 AND gen >= 0 AND capture IS NOT NULL")

        // Readable while the phone is locked after the first unlock, like the rest of our data.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        ready = true
        retryDatelessAfterReaderChange()
        repairKinds()
        migrateFromJSON(in: folder)
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
        try exec("BEGIN IMMEDIATE")
        do {
            let id = try folderID(folder, create: true)!
            try exec("UPDATE folder SET gen = \(generation) WHERE id = \(id)")

            if !results.isEmpty {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare("""
                    INSERT INTO file (folder_id, name, size, capture, read, kind, gen)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(folder_id, name, size)
                    DO UPDATE SET capture = excluded.capture, read = 1,
                                  kind = excluded.kind, gen = excluded.gen
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
        try prepare("SELECT 1 FROM folder WHERE substr(path, 1, length(?1) + 1) = ?1 || '/' "
                  + "LIMIT 1", into: &statement)
        bind(statement, 1, folder)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The folder as the last pass saw it. Lets the grid appear immediately, before the box
    /// has had a chance to answer — and it answers in seconds on a folder of 14 600 files.
    func listing(_ folder: String) throws -> [Item] {
        try open()
        guard let id = try folderID(folder, create: false) else { return [] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("""
            SELECT name, size, capture, kind FROM file WHERE folder_id = ?
            """, into: &statement)
        sqlite3_bind_int64(statement, 1, id)

        var items: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: raw)
            let capture = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            items.append(Item(
                path: folder + "/" + name,
                name: name,
                isDirectory: false,
                size: sqlite3_column_int64(statement, 1),
                modified: nil,
                mimeType: Item.Kind(code: Int(sqlite3_column_int64(statement, 3)))?.mimeHint,
                captureDate: capture
            ))
        }

        var children: OpaquePointer?
        defer { sqlite3_finalize(children) }
        let scope = "substr(path, 1, length(?1) + 1) = ?1 || '/'"
        try prepare("SELECT path FROM folder WHERE " + scope, into: &children)
        bind(children, 1, folder)
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
            // Prefix match rather than LIKE: a path may legitimately contain % or _.
            let scope = "path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'"

            var folders: OpaquePointer?
            defer { sqlite3_finalize(folders) }
            try prepare("UPDATE folder SET gen = ?2 WHERE " + scope, into: &folders)
            bind(folders, 1, folder)
            sqlite3_bind_int64(folders, 2, generation)
            guard sqlite3_step(folders) == SQLITE_DONE else { throw Failure.write(message) }

            var files: OpaquePointer?
            defer { sqlite3_finalize(files) }
            let sql = "UPDATE file SET gen = ?2 WHERE folder_id IN "
                    + "(SELECT id FROM folder WHERE " + scope + ")"
            try prepare(sql, into: &files)
            bind(files, 1, folder)
            sqlite3_bind_int64(files, 2, generation)
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

    /// What a folder tile shows, summed over the folder and everything beneath it — a parent
    /// full of subfolders would otherwise claim to be empty.
    func stats(for folders: [String]) throws -> [String: FolderStats] {
        try open()
        guard !folders.isEmpty else { return [:] }

        let scope = "path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'"

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
            bind(totals, 1, folder)
            guard sqlite3_step(totals) == SQLITE_ROW,
                  sqlite3_column_type(totals, 0) != SQLITE_NULL else { continue }
            let count = Int(sqlite3_column_int64(totals, 0))
            let bytes = sqlite3_column_type(totals, 1) == SQLITE_NULL
                ? nil : sqlite3_column_int64(totals, 1)

            sqlite3_reset(span)
            bind(span, 1, folder)
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
}
