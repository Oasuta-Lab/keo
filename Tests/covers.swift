import Foundation

/// La couverture d'une tuile de dossier se choisit dans le vrai SQLite, sur un répertoire
/// jetable : c'est une requête de classement, et un classement qui se trompe ne se voit qu'à
/// l'œil, sur l'appareil.
func checkFolderCovers() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-covers-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func media(_ name: String, in folder: String, size: Int64 = 2_048) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: nil)
    }
    func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_600_000_000 + n * 86_400) }

    let store = IndexStore(directory: home)
    let generation = try await store.beginGeneration()

    // --- l'image l'emporte sur la vidéo, même plus récente -----------------------------
    let album = "/NAS/Photos/2024"
    try await store.commit([
        (media("vieille.jpg", in: album), day(1)),
        (media("recente.jpg", in: album), day(9)),
        (media("hier.mov", in: album), day(10)),
    ], in: album, generation: generation)

    var covers = try await store.covers(for: [album])
    assert(covers[album]?.first?.name == "recente.jpg",
           "image la plus récente, pas la vidéo plus récente encore — \(covers[album]?.first?.name ?? "rien")")
    assert(covers[album]?.first?.path == album + "/recente.jpg", "le chemin complet sert à la vignette")
    assert(covers[album]?.first?.kind == .image, "le genre est relu depuis l'index, pas deviné à vide")

    // --- déterminisme : deux appels, la même couverture --------------------------------
    let again = try await store.covers(for: [album])
    assert(again[album]?.first?.path == covers[album]?.first?.path, "la même visite ne change pas la couverture")

    // --- à dates égales, le départage reste total --------------------------------------
    let tie = "/NAS/Photos/Ex aequo"
    try await store.commit([
        (media("b.jpg", in: tie), day(5)),
        (media("a.jpg", in: tie), day(5)),
    ], in: tie, generation: generation)
    let tied = try await store.covers(for: [tie])
    assert(tied[tie]?.first?.name == "a.jpg", "même date : le nom tranche — \(tied[tie]?.first?.name ?? "rien")")

    // --- une photo sans date EXIF ne passe pas devant une photo datée ------------------
    let partial = "/NAS/Photos/Sans date"
    try await store.commit([
        (media("inconnue.jpg", in: partial), nil),
        (media("datee.jpg", in: partial), day(2)),
    ], in: partial, generation: generation)
    let dated = try await store.covers(for: [partial])
    assert(dated[partial]?.first?.name == "datee.jpg",
           "sans date, on ne sait pas si c'est la plus récente — \(dated[partial]?.first?.name ?? "rien")")

    // --- un dossier parent emprunte à son sous-arbre -----------------------------------
    let parent = "/NAS/Photos"
    let covered = try await store.covers(for: [parent])
    assert(covered[parent]?.first?.name == "recente.jpg",
           "un parent plein de sous-dossiers emprunte la meilleure du lot — \(covered[parent]?.first?.name ?? "rien")")

    // --- seule une vidéo : elle fait l'affaire ------------------------------------------
    let clips = "/NAS/Clips"
    try await store.commit([(media("seul.mp4", in: clips), day(3))],
                           in: clips, generation: generation)
    let onlyVideo = try await store.covers(for: [clips])
    assert(onlyVideo[clips]?.first?.kind == .video, "faute d'image, la vidéo couvre la tuile")

    // --- l'éventail : plusieurs couvertures, dans le même ordre que la première --------
    let fan = try await store.covers(for: [album], limit: 3)
    assert(fan[album]?.count == 3, "trois demandées, trois rendues — \(fan[album]?.count ?? 0)")
    assert(fan[album]?.map(\.name) == ["recente.jpg", "vieille.jpg", "hier.mov"],
           "images d'abord et plus récente devant, la vidéo ferme la marche — "
         + "\(fan[album]?.map(\.name) ?? [])")
    let single = try await store.covers(for: [album])
    assert(fan[album]?.first?.name == single[album]?.first?.name,
           "demander trois ne change pas laquelle vient en tête")

    let short = try await store.covers(for: [clips], limit: 3)
    assert(short[clips]?.count == 1, "un dossier d'une seule photo en rend une, pas trois")

    // --- rien d'indexé, rien à montrer : la tuile garde son glyphe ----------------------
    let documents = "/NAS/Documents"
    try await store.commit([(media("notes.txt", in: documents), nil)],
                           in: documents, generation: generation)
    covers = try await store.covers(for: [documents, "/NAS/Jamais vu"])
    assert(covers.isEmpty, "ni média indexé ni dossier connu : aucune couverture inventée")

    let none = try await store.covers(for: [])
    assert(none.isEmpty, "aucun dossier visible : aucune requête")

    print("ok — couvertures de dossier : image avant vidéo, plus récente d'abord, déterministe, et l'éventail garde l'ordre")
}
