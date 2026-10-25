import Foundation

/// Search runs against the real store: the accent folding lives in a C function registered on
/// the connection, so a stand-in would check nothing that ships.
func checkSearch() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-search-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    // --- l'échappement SQL -------------------------------------------------------------
    assert(SearchQuery.pattern(for: "100%_brut") == "%100\\%\\_brut%",
           "les jokers SQL d'un nom de fichier doivent être échappés — "
           + SearchQuery.pattern(for: "100%_brut"))
    assert(SearchQuery.fold("Été Noël") == "ete noel", SearchQuery.fold("Été Noël"))
    assert(SearchQuery().isEmpty, "sans texte ni filtre, on n'affiche pas tout le NAS")
    assert(!SearchQuery(text: "", kinds: .videos).isEmpty, "un filtre seul est une recherche")

    let store = IndexStore(directory: home)
    let album = "/NAS/Photos/Été 2024"
    let other = "/NAS/Documents"

    func file(_ name: String, in folder: String, video: Bool = false) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: 1_024,
             modified: nil, mimeType: video ? "video/quicktime" : "image/jpeg")
    }

    let plage = file("Plage.jpg", in: album)
    let clip = file("Rentrée.mov", in: album, video: true)
    let scan = file("Facture.jpg", in: other)

    let generation = try await store.beginGeneration()
    try await store.commit([(plage, Date(timeIntervalSince1970: 1_720_000_000))], // 2024
                           in: album, generation: generation)
    try await store.commit([(clip, Date(timeIntervalSince1970: 1_100_000_000))],  // 2004
                           in: album, generation: generation)
    try await store.commit([(scan, nil)], in: other, generation: generation)

    // --- accents et casse ---------------------------------------------------------------
    var hits = try await store.search(SearchQuery(text: "rentree"))
    assert(hits.contains { $0.name == "Rentrée.mov" },
           "« rentree » doit trouver « Rentrée.mov » — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(text: "ETE 2024"))
    assert(hits.contains { $0.isDirectory && $0.name == "Été 2024" },
           "le dossier « Été 2024 » doit répondre à « ETE 2024 » — \(hits.map(\.name))")
    assert(hits.contains { $0.name == "Plage.jpg" },
           "un dossier qui matche remonte aussi ce qu'il contient — \(hits.map(\.name))")

    // --- un dossier ne remonte que sur son nom, pas sur son chemin ----------------------
    hits = try await store.search(SearchQuery(text: "Photos"))
    assert(!hits.contains { $0.isDirectory && $0.name == "Été 2024" },
           "« Photos » ne doit pas remonter tous les sous-dossiers de /Photos")

    // --- les filtres ---------------------------------------------------------------------
    hits = try await store.search(SearchQuery(kinds: .videos))
    assert(hits.map(\.name) == ["Rentrée.mov"], "filtre vidéo — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(kinds: .photos, period: .year(2024)))
    assert(hits.map(\.name) == ["Plage.jpg"], "photos de 2024 — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(text: "ete", period: .year(2024)))
    assert(!hits.contains { $0.isDirectory }, "une période exclut les dossiers, qui n'ont pas de date")

    // --- favoris ---------------------------------------------------------------------------
    hits = try await store.search(SearchQuery(favouritesOnly: true))
    assert(hits.isEmpty, "aucun favori posé — \(hits.map(\.name))")
    try await store.setFavourite([plage], true)
    hits = try await store.search(SearchQuery(favouritesOnly: true))
    assert(hits.map(\.name) == ["Plage.jpg"], "filtre favoris — \(hits.map(\.name))")

    // --- l'intervalle entre deux dates --------------------------------------------------
    let day = Date(timeIntervalSince1970: 1_720_000_000)        // 3 juillet 2024
    hits = try await store.search(SearchQuery(period: .between(day, day)))
    assert(hits.map(\.name) == ["Plage.jpg"],
           "mêmes dates aux deux bouts : la journée entière, pas l'instant — \(hits.map(\.name))")

    let week = Date(timeIntervalSince1970: 1_720_000_000 - 86_400 * 7)
    hits = try await store.search(SearchQuery(period: .between(day, week)))
    assert(hits.map(\.name) == ["Plage.jpg"], "bornes inversées : on les remet à l'endroit")

    hits = try await store.search(SearchQuery(period: .between(week, week)))
    assert(hits.isEmpty, "hors de l'intervalle — \(hits.map(\.name))")

    hits = try await store.search(SearchQuery(period: .between(
        Date(timeIntervalSince1970: 1_000_000_000), day)))
    assert(hits.count == 2, "l'intervalle large reprend les deux fichiers — \(hits.map(\.name))")
    assert(!SearchQuery(period: .between(day, day)).isEmpty, "un intervalle seul est une recherche")

    // --- le contexte affiché à l'écran -------------------------------------------------------
    let years = try await store.indexedYears()
    assert(years == [2024, 2004], "années connues, plus récente d'abord — \(years)")

    // --- ordre : dossiers d'abord, puis du plus récent au plus ancien --------------------------
    hits = try await store.search(SearchQuery(kinds: .everything))
    let dated = hits.filter { !$0.isDirectory }.compactMap(\.captureDate)
    assert(dated == dated.sorted(by: >), "les résultats datés descendent — \(dated)")

    print("ok — recherche : accents, jokers SQL, filtres type/année/intervalle/favoris, dossiers par leur nom")
}
