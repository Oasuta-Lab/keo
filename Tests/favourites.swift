import Foundation

/// Favourites and collections must outlive the index itself: a sweep, a rebuild or a folder
/// that vanishes for an evening must never take them with it. That is the point of these.
func checkFavourites() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-fav-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func photo(_ name: String, in folder: String, size: Int64 = 2_048) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: "image/jpeg")
    }
    func folder(_ path: String) -> Item {
        Item(path: path, name: (path as NSString).lastPathComponent, isDirectory: true,
             size: 0, modified: nil, mimeType: nil)
    }

    let store = IndexStore(directory: home)
    let album = "/NAS/Photos/2024"
    let a = photo("a.jpg", in: album), b = photo("b.jpg", in: album), c = photo("c.jpg", in: album)

    // --- favoris ----------------------------------------------------------------------
    var starred = try await store.isFavourite(a)
    assert(!starred, "rien n'est favori au départ")

    try await store.setFavourite([a, b], true)
    starred = try await store.isFavourite(a)
    assert(starred)
    var count = try await store.favouriteCount()
    assert(count == 2, "deux favoris — \(count)")

    try await store.setFavourite([a], true)   // deux fois de suite
    count = try await store.favouriteCount()
    assert(count == 2, "mettre deux fois en favori n'en crée pas deux — \(count)")

    try await store.setFavourite([b], false)
    count = try await store.favouriteCount()
    assert(count == 1)
    let remaining = try await store.favourites()
    assert(remaining.map(\.name) == ["a.jpg"])
    assert(remaining[0].kind == .image, "un favori reconstruit garde son type")

    // --- la date de prise de vue connue de l'index est reprise ------------------------
    let shot = Date(timeIntervalSince1970: 1_600_000_000)
    let generation = try await store.beginGeneration()
    try await store.commit([(a, shot)], in: album, generation: generation)
    let dated = try await store.favourites()
    assert(dated[0].timelineDate == shot,
           "un favori hérite de la date que l'index connaît, donc il se trie comme ailleurs")

    // --- raccourcis de dossiers --------------------------------------------------------
    let photos = folder("/NAS/Photos")
    try await store.setShortcut(photos, true)
    let isShort = try await store.isShortcut(photos)
    assert(isShort)
    let shortcuts = try await store.shortcuts()
    assert(shortcuts.map(\.name) == ["Photos"])
    assert(shortcuts[0].isDirectory && shortcuts[0].kind == .folder,
           "un raccourci reste un dossier, pas un fichier")
    try await store.setShortcut(photos, false)
    let gone = try await store.shortcuts()
    assert(gone.isEmpty)

    // --- collections --------------------------------------------------------------------
    let trips = try await store.createCollection(named: "Voyages")
    let again = try await store.createCollection(named: "  Voyages  ")
    assert(trips == again, "un même nom rend la même collection, espaces compris")

    let family = try await store.createCollection(named: "Famille")
    try await store.setMembership([a, b], in: trips, true)
    try await store.setMembership([b, c], in: family, true)

    let inTrips = try await store.items(in: trips)
    assert(Set(inTrips.map(\.name)) == ["a.jpg", "b.jpg"], "— \(inTrips.map(\.name))")

    let both = try await store.collectionsContaining(b)
    assert(both == [trips, family], "une photo peut appartenir à plusieurs collections")

    var listed = try await store.collections()
    assert(listed.map(\.name) == ["Famille", "Voyages"], "triées par nom — \(listed.map(\.name))")
    assert(listed.first { $0.id == trips }?.count == 2, "le compte suit les membres")

    try await store.setMembership([b], in: trips, false)
    let afterRemoval = try await store.items(in: trips)
    assert(afterRemoval.map(\.name) == ["a.jpg"])
    let stillInFamily = try await store.collectionsContaining(b)
    assert(stillInFamily == [family], "retirer d'une collection ne touche pas les autres")

    try await store.renameCollection(trips, to: "Vacances")
    listed = try await store.collections()
    assert(listed.map(\.name) == ["Famille", "Vacances"])

    try await store.deleteCollection(family)
    listed = try await store.collections()
    assert(listed.map(\.name) == ["Vacances"])
    let orphaned = try await store.collectionsContaining(c)
    assert(orphaned.isEmpty, "supprimer une collection emporte ses membres, en cascade")

    // --- le point qui compte : survivre au balayage de l'index -------------------------
    let swept = try await store.beginGeneration()
    try await store.sweepFolders(generation: swept)
    try await store.forgetEverything()

    let survivors = try await store.favourites()
    assert(survivors.map(\.name) == ["a.jpg"],
           "« tout relire depuis zéro » efface l'index, jamais les favoris")
    let keptCollections = try await store.collections()
    assert(keptCollections.map(\.name) == ["Vacances"], "ni les collections")
    let keptMembers = try await store.items(in: trips)
    assert(keptMembers.map(\.name) == ["a.jpg"], "ni leurs membres")

    // --- un favori dont le fichier a disparu du NAS ------------------------------------
    let shelf = IndexStore(directory: home.appendingPathComponent("shelf"))
    try FileManager.default.createDirectory(at: home.appendingPathComponent("shelf"),
                                            withIntermediateDirectories: true)
    let vanishedFile = photo("parti.jpg", in: album, size: 11)
    let stays = photo("reste.jpg", in: album, size: 22)
    let unknownFolder = photo("ailleurs.jpg", in: "/NAS/Jamais lu", size: 33)
    try await shelf.setFavourite([vanishedFile, stays, unknownFolder], true)

    // Avant toute indexation, aucun verdict : rien ne doit être accusé de manquer.
    var verdict = try await shelf.resolve([vanishedFile, stays, unknownFolder])
    assert(verdict.missing.isEmpty,
           "sans dossier indexé, on ne déclare rien manquant — \(verdict.missing.map { $0.name })")

    // Le dossier est lu de bout en bout, et « parti.jpg » n'y est pas.
    let pass = try await shelf.beginGeneration()
    try await shelf.commit([(stays, nil)], in: album, generation: pass,
                           stamp: FolderStamp.Completion(modified: Date(), childCount: 1,
                                                         mediaCount: 1, bytes: 22),
                           present: [stays], sweep: true)

    verdict = try await shelf.resolve([vanishedFile, stays, unknownFolder])
    assert(verdict.missing.map { $0.name } == ["parti.jpg"],
           "seul le fichier absent d'un dossier lu entièrement manque — \(verdict.missing.map { $0.name })")
    assert(verdict.present.contains { $0.name == "reste.jpg" })
    assert(verdict.present.contains { $0.name == "ailleurs.jpg" },
           "un dossier jamais lu ne condamne pas ses favoris")

    // --- un fichier deplace est suivi, pas declare perdu --------------------------------
    let elsewhere = "/NAS/Photos/Trie"
    let moved = photo("voyageur.jpg", in: album, size: 44)
    try await shelf.setFavourite([moved], true)
    let later = try await shelf.beginGeneration()
    try await shelf.commit([(photo("voyageur.jpg", in: elsewhere, size: 44), shot)],
                           in: elsewhere, generation: later,
                           stamp: FolderStamp.Completion(modified: Date(), childCount: 1,
                                                         mediaCount: 1, bytes: 44),
                           present: [photo("voyageur.jpg", in: elsewhere, size: 44)], sweep: true)

    verdict = try await shelf.resolve([moved])
    assert(verdict.missing.isEmpty, "un fichier retrouvé ailleurs n'est pas perdu")
    assert(verdict.present.first?.path == elsewhere + "/voyageur.jpg",
           "et son chemin est corrigé — \(String(describing: verdict.present.first?.path))")
    let repathed = try await shelf.favourites()
    assert(repathed.contains { $0.path == elsewhere + "/voyageur.jpg" },
           "la correction est persistée, pas seulement affichée")

    // --- les raccourcis suivent la même règle -------------------------------------------
    let vanished = folder("/NAS/Photos/Supprime")
    try await shelf.setShortcut(vanished, true)

    // Tant que le parent n'a pas ete lu, aucun verdict.
    var folders = try await shelf.resolveFolders([vanished])
    assert(folders.missing.isEmpty,
           "parent jamais indexé : on ne condamne pas le raccourci")

    // Le parent est lu de bout en bout, et « Supprime » n'en fait pas partie.
    let parentPass = try await shelf.beginGeneration()
    try await shelf.commit([], in: "/NAS/Photos", generation: parentPass,
                           stamp: FolderStamp.Completion(modified: Date(), childCount: 0,
                                                         mediaCount: 0, bytes: 0))
    folders = try await shelf.resolveFolders([vanished])
    assert(folders.missing.map { $0.name } == ["Supprime"],
           "un dossier absent d'un parent indexé manque — \(folders.missing.map { $0.name })")

    print("ok — favoris, raccourcis, collections, survie au balayage, et détection des disparus")
}
