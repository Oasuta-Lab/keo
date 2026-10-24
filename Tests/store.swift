import Foundation

/// Exercises the real SQLite store against a throwaway directory. These are the guarantees the
/// whole index rests on, so they are checked against the actual database, not a stand-in.
func checkIndexStore() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-check-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func photo(_ name: String, in folder: String, size: Int64 = 2_048) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: "image/jpeg")
    }

    let store = IndexStore(directory: home)
    let album = "/NAS/Photos/2024"
    let shot = Date(timeIntervalSince1970: 1_600_000_000)

    // --- écriture et relecture ---------------------------------------------------------
    let a = photo("a.jpg", in: album), b = photo("b.jpg", in: album), c = photo("c.jpg", in: album)
    var generation = try await store.beginGeneration()
    try await store.commit([(a, shot), (b, nil)], in: album, generation: generation)

    var known = try await store.known([a, b, c], in: album)
    assert(known[a.id] == shot, "une date écrite se relit")
    assert(known[b.id] == nil, "lu sans date EXIF : pas de date, mais l'entrée existe")

    var pending = try await store.unread([a, b, c], in: album)
    assert(pending.map(\.name) == ["c.jpg"],
           "seul ce qui n'a jamais été lu reste à lire — \(pending.map(\.name))")

    // --- une lecture ratée reste à réessayer ------------------------------------------
    // (rien n'est écrit pour `c` : il doit rester dans `unread`)
    let retryable = try await store.unread([c], in: album)
    assert(retryable.count == 1)

    // --- le marquage de dossier ------------------------------------------------------
    let folderTime = Date(timeIntervalSince1970: 1_700_000_000)
    var unchanged = try await store.isUnchanged(album, modified: folderTime, childCount: 3)
    assert(!unchanged, "jamais marqué, donc jamais ignoré")
    try await store.commit([(c, shot)], in: album, generation: generation,
                           stamp: (folderTime, 3), present: [a, b, c], sweep: true)
    unchanged = try await store.isUnchanged(album, modified: folderTime, childCount: 3)
    assert(unchanged, "marqué et intact : on peut l'ignorer sans même le lister")
    unchanged = try await store.isUnchanged(album, modified: folderTime.addingTimeInterval(60),
                                            childCount: 3)
    assert(!unchanged, "mtime changée : des photos ont été ajoutées, il faut relister")
    unchanged = try await store.isUnchanged(album, modified: folderTime, childCount: 4)
    assert(!unchanged, "même mtime mais le compte diffère : on relit quand même")

    // --- un fichier disparu est balayé, les autres survivent ---------------------------
    generation = try await store.beginGeneration()
    try await store.commit([], in: album, generation: generation,
                           stamp: (folderTime, 2), present: [a, c], sweep: true)
    known = try await store.known([a, b, c], in: album)
    assert(known[a.id] == shot && known[c.id] == shot, "les fichiers encore là sont conservés")
    pending = try await store.unread([b], in: album)
    assert(pending.count == 1, "b a disparu du NAS : son entrée est supprimée")

    // --- un dossier renommé ne coûte pas une relecture ---------------------------------
    let moved = photo("a.jpg", in: "/NAS/Photos/2024 - vacances")
    let inherited = try await store.adopt([moved])
    assert(inherited[moved.id] == shot,
           "même nom et même taille ailleurs : la date est retrouvée sans toucher au réseau")

    let ambiguous = photo("a.jpg", in: "/NAS/Autre", size: 2_048)
    try await store.commit([(photo("a.jpg", in: "/NAS/Autre"), shot.addingTimeInterval(99_999))],
                           in: "/NAS/Autre", generation: generation)
    let ambiguousMatch = try await store.adopt([ambiguous])
    assert(ambiguousMatch.isEmpty,
           "deux dates différentes pour le même nom et la même taille : on relit, on ne devine pas")

    // --- un sous-arbre ignoré ne doit pas être balayé ----------------------------------
    let deep = photo("d.jpg", in: "/NAS/Photos/2024/Juin")
    try await store.commit([(deep, shot)], in: "/NAS/Photos/2024/Juin", generation: generation)

    generation = try await store.beginGeneration()
    try await store.touchSubtree("/NAS/Photos", generation: generation)
    try await store.sweepFolders(generation: generation)
    let survived = try await store.known([deep], in: "/NAS/Photos/2024/Juin")
    assert(survived[deep.id] == shot,
           "un dossier ignoré car intact garde tout son sous-arbre, sinon le balayage l'effacerait")

    // --- la date glanée par les vignettes survit au balayage ---------------------------
    let opportunistic = photo("e.jpg", in: album)
    try await store.note(shot, for: opportunistic, in: album)
    generation = try await store.beginGeneration()
    try await store.commit([], in: album, generation: generation,
                           stamp: (folderTime, 3), present: [a, c, opportunistic], sweep: true)
    let glanced = try await store.known([opportunistic], in: album)
    assert(glanced[opportunistic.id] == shot,
           "une date relevée au passage par le pipeline de vignettes n'est pas balayée")

    // --- tout réindexer oublie les marquages, pas les dates ----------------------------
    try await store.forgetWalk()
    unchanged = try await store.isUnchanged(album, modified: folderTime, childCount: 3)
    assert(!unchanged, "après « tout réindexer », chaque dossier est réexaminé")
    let keptDates = try await store.known([a], in: album)
    assert(keptDates[a.id] == shot, "mais les dates déjà lues ne sont pas jetées")

    let total = try await store.fileCount()
    assert(total > 0, "l'index contient bien des lignes")

    print("ok — magasin SQLite : écriture, relecture, marquage, balayage, adoption, sous-arbres")
}

/// Une indexation déjà payée ne doit pas se re-payer : les anciens fichiers JSON sont repris.
func checkMigration() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-migration-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let shot = 1_600_000_000.0
    let folderTime = 1_700_000_000.0
    let records: [String: Double?] = [
        "/NAS/Photos/2024/a.jpg|2048": shot,
        "/NAS/Photos/2024/b.jpg|4096": nil,          // lu, sans date EXIF
        "/NAS/Photos/2024/Été/c.jpg|8192": shot,     // accents et sous-dossier
    ]
    let walked = ["/NAS/Photos/2024": folderTime]

    let dates = home.appendingPathComponent("capture-dates.json")
    let folders = home.appendingPathComponent("indexed-folders.json")
    try JSONEncoder().encode(records).write(to: dates)
    try JSONEncoder().encode(walked).write(to: folders)

    let store = IndexStore(directory: home)

    func photo(_ name: String, in folder: String, size: Int64) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: "image/jpeg")
    }
    let a = photo("a.jpg", in: "/NAS/Photos/2024", size: 2_048)
    let b = photo("b.jpg", in: "/NAS/Photos/2024", size: 4_096)
    let accented = photo("c.jpg", in: "/NAS/Photos/2024/Été", size: 8_192)

    let imported = try await store.known([a, b, accented], in: "/NAS/Photos/2024")
    assert(imported[a.id] == Date(timeIntervalSince1970: shot), "les dates migrent")
    assert(imported[b.id] == nil, "« lu, sans date » reste « lu, sans date »")

    let stillUnread = try await store.unread([a, b], in: "/NAS/Photos/2024")
    assert(stillUnread.isEmpty, "rien de migré ne doit être relu — \(stillUnread.map(\.name))")

    let deep = try await store.known([accented], in: "/NAS/Photos/2024/Été")
    assert(deep[accented.id] == Date(timeIntervalSince1970: shot),
           "un sous-dossier accentué migre aussi")

    let unchanged = try await store.isUnchanged("/NAS/Photos/2024",
                                                modified: Date(timeIntervalSince1970: folderTime),
                                                childCount: nil)
    assert(unchanged, "les dossiers déjà terminés restent terminés")

    assert(!FileManager.default.fileExists(atPath: dates.path),
           "les anciens JSON sont retirés une fois repris")
    assert(!FileManager.default.fileExists(atPath: folders.path))

    print("ok — migration depuis les anciens fichiers JSON, sans perte")
}
