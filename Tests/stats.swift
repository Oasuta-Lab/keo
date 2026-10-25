import Foundation

/// Les statistiques tournent sur le vrai SQLite : tout ce qu'elles affichent sort d'un
/// `GROUP BY`, et un regroupement faux ne se voit pas à l'œil — il se lit comme un chiffre
/// plausible. Un dépôt jetable, comme pour la recherche et les couvertures.
func checkStatistics() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-stats-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func media(_ name: String, in folder: String, size: Int64 = 1_000) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: nil)
    }
    /// Construite dans le fuseau de la machine, comme `strftime(…, 'localtime')` la relira.
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: 12))!
    }
    func stamp(_ bytes: Int64?, media: Int) -> FolderStamp.Completion {
        FolderStamp.Completion(modified: Date(), childCount: media, mediaCount: media,
                               bytes: bytes)
    }

    let store = IndexStore(directory: home)
    let generation = try await store.beginGeneration()

    // Un arbre volontairement incomplet : un dossier jamais pesé, un fichier jamais lu.
    let old = "/Photos/2023"
    try await store.commit([(media("plage.jpg", in: old), date(2023, 1, 10)),
                            (media("port.jpg", in: old), date(2023, 1, 10))],
                           in: old, generation: generation, stamp: stamp(3_000, media: 2))

    let recent = "/Photos/2024"
    try await store.commit([(media("gateau.jpg", in: recent), date(2024, 6, 14)),
                            (media("scan.jpg", in: recent), nil)],
                           in: recent, generation: generation, stamp: stamp(5_000, media: 2))
    // Vue dans un listing, jamais ouverte : elle a peut-être une date, personne n'a regardé.
    try await store.commit([], in: recent, generation: generation,
                           present: [media("jamais-lue.jpg", in: recent)])

    let raw = "/Photos/Brut"
    try await store.commit([(media("dng.jpg", in: raw), date(2024, 6, 14))],
                           in: raw, generation: generation)   // sans stamp : bytes NULL

    let clips = "/Vidéos"
    try await store.commit([(Item(path: "\(clips)/noel.mov", name: "noel.mov",
                                  isDirectory: false, size: 9_000, modified: nil,
                                  mimeType: "video/quicktime"), date(2024, 12, 25))],
                           in: clips, generation: generation, stamp: stamp(10_000, media: 1))

    let papers = "/Documents"
    try await store.commit([(Item(path: "\(papers)/cni.pdf", name: "cni.pdf",
                                  isDirectory: false, size: 100, modified: nil,
                                  mimeType: "application/pdf"), nil)],
                           in: papers, generation: generation, stamp: stamp(100, media: 0))

    let stats = try await store.statistics(under: "/", on: date(2025, 6, 14))

    // --- la racine : « ?1 || '/' » y fabrique « // » -------------------------------------
    assert(Statistics.scopePrefix("/") == "/", "la racine est déjà son propre préfixe")
    assert(Statistics.scopePrefix("/Photos") == "/Photos/", "ailleurs on ajoute la barre")
    let rootHasChildren = try await store.hasChildFolders("/")
    let naivePrefix = try await store.hasChildFolders("//")
    assert(rootHasChildren, "la racine a bien des enfants en base")
    assert(!naivePrefix,
           "et aucun chemin ne commence par « // » : l'idiome « ?1 || '/' » cherchait "
           + "exactement ça à la racine, donc la remarque du design est exacte")
    let rootTotals = try await store.stats(for: ["/"])
    assert(rootTotals["/"]?.bytes == 18_100,
           "les totaux de la racine couvrent tout l'arbre — \(String(describing: rootTotals["/"]))")

    // --- le poids : regroupement par premier segment ------------------------------------
    let names = stats.subtrees.map(\.name)
    assert(names == ["Vidéos", "Photos", "Documents"],
           "les sous-arbres de la racine, du plus lourd au plus léger — \(names)")
    let photos = stats.subtrees.first { $0.name == "Photos" }!
    assert(photos.path == "/Photos", "le chemin doit pouvoir s'ouvrir tel quel")
    assert(photos.bytes == 8_000, "8 000 pesés sur trois dossiers — \(photos.bytes)")
    assert(photos.folders == 3 && photos.unweighed == 1,
           "un des trois n'a jamais été pesé — \(photos.folders)/\(photos.unweighed)")
    assert(photos.weight.hasPrefix("≥ "),
           "un sous-arbre incomplet annonce un plancher, pas un total — \(photos.weight)")
    assert(photos.weight.contains("1 dossier pas encore pesé"), photos.weight)
    let videos = stats.subtrees.first { $0.name == "Vidéos" }!
    assert(!videos.weight.hasPrefix("≥"), "tout est pesé ici : le total est ferme — \(videos.weight)")
    assert(videos.fraction(of: 10_000) == 1 && photos.fraction(of: 10_000) == 0.8,
           "les barres sont proportionnelles au plus lourd")

    // --- et sous un dossier quelconque, pas seulement la racine --------------------------
    let inside = try await store.heaviestSubtrees(under: "/Photos")
    assert(inside.map(\.name) == ["2024", "2023", "Brut"], "\(inside.map(\.name))")
    assert(inside.last?.bytes == 0 && inside.last?.unweighed == 1,
           "jamais pesé : zéro affiché comme inconnu, pas comme vide")
    assert(inside.last?.fraction(of: 5_000) == 0,
           "rien de pesé, rien à dessiner — une barre inventerait une mesure")
    let unknown = try await store.heaviestSubtrees(under: "/Jamais vu")
    assert(unknown.isEmpty, "un dossier inconnu n'a aucun sous-arbre")

    // --- la chronologie -------------------------------------------------------------------
    assert(stats.years.map(\.year) == [2023, 2024], "\(stats.years.map(\.year))")
    let last = stats.years.last!
    assert(last.photos == 2 && last.videos == 1,
           "2024 : deux photos datées et une vidéo — \(last.photos)/\(last.videos)")
    assert(stats.firstCapture == date(2023, 1, 10), "la première prise de vue connue")

    // --- les deux « sans date », qui ne doivent jamais fusionner ---------------------------
    assert(stats.datelessRead == 1,
           "une photo lue de bout en bout et sans date EXIF — \(stats.datelessRead)")
    assert(stats.datelessUnread == 1,
           "une photo jamais ouverte, dont on ne sait rien — \(stats.datelessUnread)")
    assert(stats.datelessRead != stats.datelessRead + stats.datelessUnread,
           "deux vérités différentes : une sur les fichiers, une sur l'index")
    assert(stats.unreadFiles == 1, "le bandeau compte les fichiers jamais lus — \(stats.unreadFiles)")
    let dateless = try await store.datelessFiles()
    assert(dateless.map(\.name) == ["scan.jpg"],
           "la ligne « sans date » ouvre sur ces fichiers-là, pas sur toutes les photos, "
           + "et pas sur celles que personne n'a lues — \(dateless.map(\.name))")
    assert(stats.knownFolders == 5 && stats.indexedFolders == 4,
           "5 dossiers connus, 4 pesés de bout en bout — "
           + "\(stats.knownFolders)/\(stats.indexedFolders)")
    assert(stats.isPartial, "index partiel : le bandeau doit s'afficher")
    assert(stats.coverage.contains("4 dossiers indexés") && stats.coverage.contains("sur 5"),
           stats.coverage)

    // --- le plus long silence ---------------------------------------------------------------
    assert(stats.gap == Gap(silentMonths: 16, from: 2023 * 12, to: 2024 * 12 + 5),
           "janvier 2023 → juin 2024 : seize mois sans photo — \(String(describing: stats.gap))")
    assert(stats.gap?.label.hasPrefix("16 mois sans photo, janv. 2023 – juin 2024") == true,
           stats.gap?.label ?? "rien")
    assert(Statistics.longestGap([]) == nil && Statistics.longestGap([24_000]) == nil,
           "un seul mois ne fait pas un trou")
    assert(Statistics.longestGap([10, 11, 12]) == nil, "trois mois de suite non plus")
    assert(Statistics.longestGap([10, 13, 20, 23]) == Gap(silentMonths: 6, from: 13, to: 20),
           "le plus long l'emporte")
    assert(Statistics.longestGap([10, 13, 20, 23]) == Statistics.longestGap([23, 13, 10, 20]),
           "l'ordre d'arrivée ne change rien")

    // --- le tri par type, une phrase et pas un camembert ------------------------------------
    let sentence = Statistics.kindSentence(stats.kinds) ?? ""
    assert(sentence.contains("6 photos") && sentence.contains("1 vidéo")
           && sentence.contains("1 autre fichier"),
           "tout ce qu'un listing a montré, y compris jamais lu — \(sentence)")
    assert(Statistics.kindSentence([]) == nil, "rien d'indexé : pas de phrase")

    // --- les doublons probables ----------------------------------------------------------
    assert(stats.duplicates.groups == 0, "rien d'identique pour l'instant")
    let copy = media("plage.jpg", in: clips)        // même nom, même taille, ailleurs
    let lookalike = media("plage.jpg", in: papers, size: 2_000)  // même nom, autre taille
    try await store.commit([(copy, date(2023, 1, 10)), (lookalike, nil)],
                           in: clips, generation: generation)
    try await store.commit([(lookalike, nil)], in: papers, generation: generation)

    let totals = try await store.duplicateTotals()
    assert(totals.groups == 2, "deux groupes : 1 000 octets ×2, 2 000 octets ×2 — \(totals.groups)")
    assert(totals.extraFiles == 2, "un exemplaire en trop par groupe — \(totals.extraFiles)")
    assert(totals.recoverableBytes == 3_000,
           "on ne compte jamais le premier exemplaire — \(totals.recoverableBytes)")

    let worst = try await store.worstDuplicates()
    assert(worst.first?.name == "plage.jpg" && worst.first?.size == 2_000,
           "le plus coûteux d'abord, pas le plus nombreux — \(String(describing: worst.first))")
    assert(worst.first?.copies == 2, "\(String(describing: worst.first?.copies))")
    assert(worst.first?.detail.contains("2 exemplaires") == true, worst.first?.detail ?? "")

    let where1 = try await store.copies(of: worst.first!)
    assert(Set(where1.map(\.path)) == ["/Vidéos/plage.jpg", "/Documents/plage.jpg"],
           "le groupe ouvre sur les emplacements réels — \(where1.map(\.path))")
    let identical = try await store.copies(of: DuplicateGroup(name: "plage.jpg", size: 1_000,
                                                              copies: 2))
    assert(Set(identical.map(\.path)) == ["/Photos/2023/plage.jpg", "/Vidéos/plage.jpg"],
           "même nom et même taille, deux dossiers — \(identical.map(\.path))")

    // --- les plus gros fichiers, et où ils sont --------------------------------------------
    let fresh = try await store.statistics(under: "/", on: date(2025, 6, 14))
    assert(fresh.biggest.first?.name == "noel.mov", "\(String(describing: fresh.biggest.first?.name))")
    assert(BrowserSource.parent(of: fresh.biggest.first!)
           == .folder(path: "/Vidéos", title: "Vidéos"),
           "chaque ligne doit mener quelque part : ici le dossier qui contient le fichier")

    // --- les jours les plus photographiés ---------------------------------------------------
    let busiest = fresh.busiestDays.first!
    assert(busiest.count == 3 && Calendar.current.isDate(busiest.day, inSameDayAs: date(2023, 1, 10)),
           "le 10 janvier 2023 : trois prises, dont la copie — \(busiest.count)")
    assert(SearchQuery.Period.between(busiest.day, busiest.day).range() != nil,
           "la ligne se convertit en filtre « journée entière »")
    let thatDay = try await store.search(SearchQuery(period: .between(busiest.day, busiest.day)))
    assert(thatDay.count == 3, "et ce filtre retrouve bien les trois — \(thatDay.map(\.name))")

    // --- ce jour-là, les années précédentes --------------------------------------------------
    assert(fresh.onThisDay.map(\.name) == ["gateau.jpg", "dng.jpg"],
           "un 14 juin d'avant, plus récent d'abord puis par chemin — "
           + "\(fresh.onThisDay.map(\.name))")
    let nothing = try await store.statistics(under: "/", on: date(2025, 3, 2)).onThisDay
    assert(nothing.isEmpty, "aucune photo un 2 mars : la section disparaît")
    let today = try await store.statistics(under: "/", on: date(2024, 6, 14)).onThisDay
    assert(today.isEmpty,
           "les photos du jour même ne sont pas un souvenir — \(today.map(\.name))")

    print("ok — statistiques : racine, sous-arbres pesés ou non, sans date vs jamais lue, "
        + "doublons par nom+taille, plus gros fichiers, jours chargés, ce jour-là")
}


/// La racine satisfait son propre préfixe « / ». Sans garde de longueur, elle remontait donc
/// parmi ses propres sous-dossiers : une tuile « / » à la racine, dans laquelle on pouvait
/// entrer indéfiniment. Son propre bac à sable, parce qu'il lui faut une ligne pour « / »
/// que le reste des statistiques n'a pas.
func checkRootIsNotItsOwnChild() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-racine-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = IndexStore(directory: home)
    let generation = try await store.beginGeneration()
    try await store.commit([], in: "/", generation: generation)
    try await store.commit([], in: "/Perso", generation: generation)
    try await store.commit([], in: "/Perso/Photos", generation: generation)

    let children = try await store.listing("/")
    assert(!children.contains { $0.path == "/" },
           "la racine ne figure pas parmi ses propres enfants — \(children.map(\.path))")
    assert(children.map(\.path) == ["/Perso"],
           "seulement ses enfants directs — \(children.map(\.path))")

    let deeper = try await store.listing("/Perso")
    assert(deeper.map(\.path) == ["/Perso/Photos"],
           "et la même règle plus bas — \(deeper.map(\.path))")

    // La garde ne doit pas priver la racine de ses enfants pour autant : c'est le bug que la
    // garde elle-même a failli réintroduire dans l'autre sens.
    let hasChildren = try await store.hasChildFolders("/")
    assert(hasChildren, "la racine a bien des sous-dossiers connus")

    print("ok — la racine n'est pas son propre sous-dossier, et garde les siens")
}
