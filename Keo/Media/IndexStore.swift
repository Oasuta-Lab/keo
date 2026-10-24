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
    private static let readerVersion: Int64 = 2

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
