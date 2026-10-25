import Foundation

/// Notes are the only personalisation whose *content* changes, so they are the only ones where
/// two devices can hold genuinely different data for the same record. That is what this checks.
func checkNotes() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-notes-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = IndexStore(directory: home)
    let photo = Item(path: "/NAS/Photos/IMG_4821.HEIC", name: "IMG_4821.HEIC",
                     isDirectory: false, size: 3_200_000, modified: nil, mimeType: "image/heic")
    let album = Item(path: "/NAS/Photos/Impôts", name: "Impôts", isDirectory: true,
                     size: 0, modified: nil, mimeType: nil)

    // --- écriture, relecture, effacement --------------------------------------------------
    var body = try await store.note(on: photo)
    assert(body == nil, "pas de note au départ")

    try await store.setNote("Facture EDF, à garder", on: photo)
    body = try await store.note(on: photo)
    assert(body == "Facture EDF, à garder", "ce qui est écrit se relit — \(body ?? "rien")")

    let marked = try await store.notedPaths()
    assert(marked == [photo.path], "le marquage voit la note — \(marked)")

    // Une note vidée est une note supprimée, pas une ligne contenant "" que la recherche
    // remonterait sur n'importe quelle requête.
    try await store.setNote("   \n  ", on: photo)
    body = try await store.note(on: photo)
    var count = try await store.noteCount()
    assert(body == nil && count == 0, "une note vidée disparaît — \(String(describing: body))")

    try await store.setNote("  Facture EDF  ", on: photo)
    body = try await store.note(on: photo)
    assert(body == "Facture EDF", "les espaces autour sont rognés — « \(body ?? "") »")

    // --- un dossier s'annote aussi ----------------------------------------------------------
    try await store.setNote("Tout est scanné, originaux au grenier", on: album)
    count = try await store.noteCount()
    assert(count == 2, "fichier et dossier annotés — \(count)")

    // --- cherchable par son contenu -----------------------------------------------------------
    let generation = try await store.beginGeneration()
    try await store.commit([(photo, nil)], in: "/NAS/Photos", generation: generation)
    // Le dossier doit exister dans l'index pour pouvoir remonter : une note sur un dossier
    // jamais parcouru reste invisible, comme tout le reste de la recherche.
    try await store.commit([], in: album.path, generation: generation)

    var hits = try await store.search(SearchQuery(text: "facture"))
    assert(hits.contains { $0.name == "IMG_4821.HEIC" },
           "une note rend trouvable un fichier dont le nom ne dit rien — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(text: "GRENIER"))
    assert(hits.contains { $0.isDirectory && $0.name == "Impôts" },
           "la note d'un dossier aussi, sans accent ni casse — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(text: "introuvable-nulle-part"))
    assert(hits.isEmpty, "et pas de faux positif — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(notedOnly: true))
    assert(hits.map(\.name) == ["IMG_4821.HEIC"],
           "le filtre Notes ne garde que l'annoté — \(hits.map(\.name))")

    // --- synchronisation : le dernier écrivain gagne, pas le dernier arrivé -------------------
    let path = photo.path, size = photo.size
    func incoming(_ text: String, at stamp: Double) -> SyncPayload {
        .note(path: path, name: photo.name, size: size, body: text, modified: stamp)
    }

    let mine = try await store.note(on: photo)
    try await store.applyRemote(saves: [incoming("écrit avant", at: 1)], deletes: [])
    body = try await store.note(on: photo)
    assert(body == mine,
           "une édition plus ancienne arrivée après ne doit pas écraser la locale — « \(body ?? "") »")

    try await store.applyRemote(saves: [incoming("écrit après", at: 9_999_999_999)], deletes: [])
    body = try await store.note(on: photo)
    assert(body == "écrit après", "une édition plus récente gagne — « \(body ?? "") »")

    // Un enregistrement tronqué est jeté, pas appliqué à moitié.
    var broken = incoming("peu importe", at: 9_999_999_999)
    broken.body = nil
    assert(broken.identity == nil, "une note sans texte n'a pas d'identité")

    // --- le journal rejoue la date de la note, pas celle du rejeu ------------------------------
    try await store.journalAllPersonalisation()
    let pending = try await store.pendingSyncChanges()
    let replayed = pending.compactMap { SyncPayload.decoded(from: $0.payload ?? "") }
        .first { $0.kind == "note" && $0.path == path }
    assert(replayed?.modified == 9_999_999_999,
           "rejouer le journal ne doit pas faire passer une note périmée pour la plus récente — "
           + String(describing: replayed?.modified))

    // --- suppression distante : le biais de résurrection d'abord -------------------------------
    // Une note qu'on vient d'écrire ici a une sauvegarde en attente. Une suppression venue
    // d'ailleurs ne doit pas l'emporter : on ne perd pas un texte que quelqu'un vient de taper.
    let name = SyncIdentity.note(path: path, size: size).recordName
    try await store.applyRemote(saves: [], deletes: [name])
    body = try await store.note(on: photo)
    assert(body == "écrit après",
           "une suppression distante ne bat pas une sauvegarde locale en attente — « \(body ?? "") »")

    // Une fois la sauvegarde acquittée par le serveur, la suppression s'applique.
    try await store.clearSyncPendingSave(recordName: name, ifUnchangedSince: 9_999_999_999)
    try await store.applyRemote(saves: [], deletes: [name])
    body = try await store.note(on: photo)
    let folderNote = try await store.note(on: album)
    assert(body == nil, "suppression distante appliquée une fois la locale acquittée")
    assert(folderNote != nil, "et seulement celle-là")

    print("ok — notes : écriture, effacement, recherche par contenu, LWW, journal, résurrection, suppression distante")
}
