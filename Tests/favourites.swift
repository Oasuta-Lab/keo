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

    print("ok — favoris, raccourcis, collections, et leur survie au balayage de l'index")
}
