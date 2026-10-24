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
                           stamp: FolderStamp.Completion(modified: folderTime, childCount: 3,
                                                         mediaCount: 3, bytes: 6_144),
                           present: [a, b, c], sweep: true)
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
                           stamp: FolderStamp.Completion(modified: folderTime, childCount: 2,
                                                         mediaCount: 2, bytes: 4_096),
                           present: [a, c], sweep: true)
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
                           stamp: FolderStamp.Completion(modified: folderTime, childCount: 3,
                                                         mediaCount: 3, bytes: 6_144),
                           present: [a, c, opportunistic], sweep: true)
    let glanced = try await store.known([opportunistic], in: album)
    assert(glanced[opportunistic.id] == shot,
           "une date relevée au passage par le pipeline de vignettes n'est pas balayée")

    // --- revérifier : on reliste tout, on ne relit rien --------------------------------
    try await store.forgetWalk()
    unchanged = try await store.isUnchanged(album, modified: folderTime, childCount: 3)
    assert(!unchanged, "après « revérifier », chaque dossier est réexaminé")
    let keptDates = try await store.known([a], in: album)
    assert(keptDates[a.id] == shot, "mais aucune date déjà lue n'est jetée")
    let nothingToReread = try await store.unread([a], in: album)
    assert(nothingToReread.isEmpty, "donc rien n'est à relire sur le NAS")

    let total = try await store.fileCount()
    assert(total > 0, "l'index contient bien des lignes")

    // --- les totaux affichés sur les tuiles ------------------------------------------
    let tree = IndexStore(directory: home.appendingPathComponent("tree"))
    try FileManager.default.createDirectory(at: home.appendingPathComponent("tree"),
                                            withIntermediateDirectories: true)
    let gen = try await tree.beginGeneration()
    let old = Date(timeIntervalSince1970: 1_500_000_000)   // 2017
    let recent = Date(timeIntervalSince1970: 1_700_000_000) // 2023

    // Le dossier parent contient aussi un document, qui doit compter dans le poids.
    let parentPhoto = photo("p.jpg", in: "/NAS/Album", size: 1_000)
    let childPhoto = photo("q.jpg", in: "/NAS/Album/Juin", size: 3_000)
    try await tree.commit([(parentPhoto, old)], in: "/NAS/Album", generation: gen,
                          stamp: FolderStamp.Completion(modified: Date(), childCount: 3,
                                                        mediaCount: 1, bytes: 1_000 + 500_000))
    try await tree.commit([(childPhoto, recent)], in: "/NAS/Album/Juin", generation: gen,
                          stamp: FolderStamp.Completion(modified: Date(), childCount: 1,
                                                        mediaCount: 1, bytes: 3_000))

    let stats = try await tree.stats(for: ["/NAS/Album", "/NAS/Album/Juin"])
    let parent = stats["/NAS/Album"]
    assert(parent?.mediaCount == 2,
           "un dossier parent compte aussi ce que contiennent ses sous-dossiers — \(String(describing: parent?.mediaCount))")
    assert(parent?.bytes == 504_000,
           "le poids cumule le sous-arbre et compte les documents, pas seulement les médias — "
         + "\(String(describing: parent?.bytes))")
    assert(parent?.mediaCount == 2, "le compteur, lui, ne parle que de photos et vidéos")
    assert(parent?.span == "2017 – 2023",
           "la période couvre tout le sous-arbre — \(String(describing: parent?.span))")

    let child = stats["/NAS/Album/Juin"]
    assert(child?.mediaCount == 1 && child?.span == "2023",
           "un dossier d'une seule année n'affiche qu'une année")

    let unseen = try await tree.stats(for: ["/NAS/Jamais vu"])
    assert(unseen.isEmpty, "un dossier jamais indexé n'invente pas de totaux")

    // --- le listing mémorisé, qui peint la grille avant la box ------------------------
    let cached = try await tree.listing("/NAS/Album")
    assert(cached.contains { $0.name == "p.jpg" && !$0.isDirectory },
           "le fichier lu est restitué — \(cached.map(\.name))")
    assert(cached.contains { $0.name == "Juin" && $0.isDirectory },
           "les sous-dossiers directs aussi, pour que la navigation marche de mémoire")
    assert(!cached.contains { $0.name == "q.jpg" },
           "mais pas le contenu des sous-dossiers : un listing, pas un arbre")
    assert(cached.first { $0.name == "p.jpg" }?.kind == .image,
           "le type est conservé, sinon la grille ne saurait pas quoi afficher")
    assert(cached.first { $0.name == "p.jpg" }?.timelineDate == old,
           "et la date de prise de vue avec, donc le tri marche dès le premier rendu")

    // Un fichier jamais lu doit quand même figurer au listing, sinon la grille serait
    // incomplète tant que l'indexation n'est pas passée.
    let never = photo("z.jpg", in: "/NAS/Album", size: 77)
    let gen2 = try await tree.beginGeneration()
    try await tree.commit([], in: "/NAS/Album", generation: gen2,
                          stamp: FolderStamp.Completion(modified: Date(), childCount: 4,
                                                        mediaCount: 2, bytes: 501_077),
                          present: [parentPhoto, never], sweep: true)
    let withUnread = try await tree.listing("/NAS/Album")
    assert(withUnread.contains { $0.name == "z.jpg" },
           "un fichier vu mais jamais lu figure au listing — \(withUnread.map(\.name))")
    let stillToRead = try await tree.unread([never], in: "/NAS/Album")
    assert(stillToRead.count == 1,
           "et il reste à lire : présent au listing n'est pas lu")

    // --- un dossier intact mais qui a des enfants doit quand même être listé -----------
    // C'est le bug qui cassait la reprise : /NAS était sauté comme « intact », donc jamais
    // listé, donc ses sous-dossiers jamais découverts, et le parcours se croyait terminé.
    let branching = try await tree.hasChildFolders("/NAS/Album")
    assert(branching, "/NAS/Album a un sous-dossier connu de l'index")
    let leaf = try await tree.hasChildFolders("/NAS/Album/Juin")
    assert(!leaf, "/NAS/Album/Juin n'en a pas : lui peut être sauté sans rien cacher")
    let unknownBranch = try await tree.hasChildFolders("/NAS/Jamais")
    assert(!unknownBranch, "un dossier inconnu n'a pas d'enfants connus")

    // --- un meilleur lecteur fait réessayer les photos restées sans date ---------------
    let reader = home.appendingPathComponent("reader")
    try FileManager.default.createDirectory(at: reader, withIntermediateDirectories: true)
    let dated = photo("avec.jpg", in: "/NAS/Vieux", size: 10)
    let undatedYet = photo("sans.jpg", in: "/NAS/Vieux", size: 20)

    let before2 = IndexStore(directory: reader)
    let g2 = try await before2.beginGeneration()
    try await before2.commit([(dated, shot), (undatedYet, nil)], in: "/NAS/Vieux",
                             generation: g2,
                             stamp: FolderStamp.Completion(modified: folderTime, childCount: 2,
                                                           mediaCount: 2, bytes: 30))
    try await before2.rewindReaderVersionForChecks()

    let after2 = IndexStore(directory: reader)
    let toRetry = try await after2.unread([dated, undatedYet], in: "/NAS/Vieux")
    assert(toRetry.map(\.name) == ["sans.jpg"],
           "seules les photos restées sans date sont réessayées — \(toRetry.map(\.name))")
    let keptAfterUpgrade = try await after2.known([dated], in: "/NAS/Vieux")
    assert(keptAfterUpgrade[dated.id] == shot, "une date déjà trouvée n'est jamais rejetée")
    let reopened = try await after2.isUnchanged("/NAS/Vieux", modified: folderTime, childCount: 2)
    assert(!reopened, "et leur dossier ne peut plus se dire terminé")

    let nothing = try await tree.listing("/NAS/Inconnu")
    assert(nothing.isEmpty, "un dossier inconnu ne fabrique pas de listing")

    // --- aucune ligne de fichier ne peut ressortir en dossier --------------------------
    // Le defaut de la colonne kind valait "dossier" : toutes les photos deja indexees
    // revenaient du cache comme des dossiers dans lesquels on pouvait entrer.
    for item in withUnread where !item.isDirectory {
        assert(item.kind != .folder,
               "un fichier ne doit jamais ressortir comme dossier — \(item.name)")
    }
    assert(Item.Kind.folder.mimeHint == nil,
           "aucun mimeType ne doit pouvoir transformer un fichier en dossier")
    assert(Item(path: "/a/x.jpg", name: "x.jpg", isDirectory: false, size: 1,
                modified: nil, mimeType: "inode/directory").kind != .folder,
           "seul isDirectory décide : un mimeType de dossier sur un fichier est ignoré")

    // Une base ecrite avant la colonne : les kind valent 0 et doivent etre repares.
    let legacy = home.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let before = IndexStore(directory: legacy)
    let g = try await before.beginGeneration()
    try await before.commit([(photo("v.mp4", in: "/NAS/Vieux", size: 10), nil)],
                            in: "/NAS/Vieux", generation: g)
    try await before.rewriteKindsAsUnknownForChecks()

    let after = IndexStore(directory: legacy)
    let repaired = try await after.listing("/NAS/Vieux")
    assert(repaired.first?.kind == .video,
           "une base d'avant la colonne est réparée d'après le nom — \(String(describing: repaired.first?.kind))")

    // --- tout relire depuis zéro : là, tout repart vraiment ----------------------------
    try await store.forgetEverything()
    let wiped = try await store.known([a], in: album)
    assert(wiped.isEmpty, "les dates sont bien effacées")
    let allToReread = try await store.unread([a, c], in: album)
    assert(allToReread.count == 2, "et tout est à relire — \(allToReread.count)")
    let emptied = try await store.fileCount()
    assert(emptied == 0, "l'index ne contient plus rien — \(emptied)")
    let noStamp = try await store.isUnchanged(album, modified: folderTime, childCount: 3)
    assert(!noStamp, "aucun dossier n'est plus marqué terminé")


    print("ok — magasin SQLite : écriture, marquage, balayage, adoption, sous-arbres, totaux")
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
