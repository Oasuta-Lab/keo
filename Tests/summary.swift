import Foundation

/// Le résumé de fin de marche : ce qui se dit, ce qui se tait, et les deux chiffres que seul
/// le magasin peut donner — les arrivées de la passe et ce que le balayage a emporté.
func checkWalkSummary() {
    // Un zéro ne se dit jamais. Une passe tranquille sur une bibliothèque indexée ne doit pas
    // débiter sept compteurs vides pour annoncer qu'il ne s'est rien passé.
    let quiet = WalkSummary(foldersVisited: 0, foldersSkipped: 8_300, indexedOverall: 40_861)
    assert(quiet.changedNothing)
    assert(quiet.headline == "Rien de neuf", "obtenu « \(quiet.headline) »")
    assert(!quiet.details.contains { $0.contains("date") }, "aucune date lue : rien à en dire")
    assert(!quiet.details.contains { $0.contains("illisible") })
    // Zéro parcouru et tout inchangé est le cas courant sur une bibliothèque posée : la
    // phrase ne doit pas commencer par « 0 dossier parcouru ».
    assert(quiet.details.first == Plural.count(8_300, "dossier inchangé", "dossiers inchangés"),
           "les dossiers sautés expliquent pourquoi la passe a été si courte : \(quiet.details)")
    assert(!(quiet.details.first ?? "").hasPrefix("0 "),
           "un zéro ne se dit jamais, même accompagné : \(quiet.details)")

    // Le singulier français, y compris pour l'accord de « nouveau ».
    let one = WalkSummary(arrived: 1)
    assert(one.headline == "1 nouveau fichier", "obtenu « \(one.headline) »")
    assert(!one.changedNothing)
    let few = WalkSummary(arrived: 3)
    assert(few.headline == "3 nouveaux fichiers", "obtenu « \(few.headline) »")

    // Disparu, pas supprimé : Keo ne touche jamais aux données du NAS, et le dire autrement
    // dans sa propre interface serait un aveu de quelque chose qui n'a pas eu lieu.
    let gone = WalkSummary(vanished: 2)
    assert(gone.headline == "2 fichiers disparus", "obtenu « \(gone.headline) »")
    assert(!gone.headline.lowercased().contains("supprim"),
           "l'app en lecture seule ne doit nulle part dire qu'elle a supprimé quelque chose")

    let both = WalkSummary(arrived: 12, vanished: 1)
    assert(both.headline == "12 nouveaux fichiers, 1 disparu", "obtenu « \(both.headline) »")

    // L'ordre : ce qui a changé d'abord, le total général en dernier.
    let full = WalkSummary(arrived: 4, foldersVisited: 120, foldersSkipped: 9,
                           datesRead: 412, dateless: 17, unreadable: 3, indexedOverall: 40_861)
    assert(full.details.count == 4, "obtenu \(full.details)")
    assert(full.details[0] == "120 dossiers parcourus, \(9.formatted()) inchangés",
           "obtenu « \(full.details[0]) »")
    assert(full.details[1] == "412 dates de prise de vue lues, 17 sans date",
           "obtenu « \(full.details[1]) » (espaces fines insécables comprises)")
    assert(full.details[2] == "3 fichiers illisibles")
    assert(full.details.last == Plural.count(40_861, "fichier indexé en tout",
                                             "fichiers indexés en tout"),
           "le total général ferme la liste : \(full.details)")

    print("ok — résumé de marche : les zéros se taisent, le pluriel s'accorde, "
        + "et rien n'est jamais dit « supprimé »")
}

/// Le balayage compte ce qu'il emporte, et les arrivées se comptent par horodatage.
func checkSweepCounts() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-sweep-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func file(_ path: String, size: Int64 = 2_048) -> Item {
        Item(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
             size: size, modified: nil, mimeType: "image/jpeg")
    }
    let store = IndexStore(directory: home)
    let stamp = FolderStamp.Completion(modified: Date(timeIntervalSince1970: 1_700_000_000),
                                       childCount: 2, mediaCount: 2, bytes: 4_096)

    // --- première passe : deux dossiers, trois fichiers -------------------------------
    var generation = try await store.beginGeneration()
    try await store.commit([(file("/A/un.jpg"), nil), (file("/A/deux.jpg"), nil)],
                           in: "/A", generation: generation, stamp: stamp,
                           present: [file("/A/un.jpg"), file("/A/deux.jpg")])
    try await store.commit([(file("/B/trois.jpg"), nil)],
                           in: "/B", generation: generation, stamp: stamp,
                           present: [file("/B/trois.jpg")])
    var swept = try await store.sweepFolders(generation: generation)
    assert(swept == 0, "la génération courante ne balaie pas ses propres dossiers — \(swept)")
    var total = try await store.fileCount()
    assert(total == 3)

    let between = Date().timeIntervalSince1970
    try await Task.sleep(for: .milliseconds(1_100))

    // --- deuxième passe : /A gagne un fichier, /B n'est plus listé --------------------
    generation = try await store.beginGeneration()
    try await store.commit([(file("/A/un.jpg"), nil), (file("/A/deux.jpg"), nil),
                            (file("/A/quatre.jpg"), nil)],
                           in: "/A", generation: generation, stamp: stamp,
                           present: [file("/A/un.jpg"), file("/A/deux.jpg"),
                                     file("/A/quatre.jpg")])

    let arrived = try await store.arrivalsSince(between)
    assert(arrived == 1, "seul /A/quatre.jpg est neuf depuis le repère — obtenu \(arrived)")
    let everything = try await store.arrivalsSince(0)
    assert(everything == 1,
           "le premier passage n'a produit aucune arrivée : le dossier n'était pas encore "
         + "tamponné — obtenu \(everything)")

    // --- le balayage dit ce qu'il emporte ---------------------------------------------
    swept = try await store.sweepFolders(generation: generation)
    assert(swept == 1, "/B emporte son unique fichier par cascade — obtenu \(swept)")
    total = try await store.fileCount()
    assert(total == 3, "les trois fichiers de /A restent — obtenu \(total)")

    // Compté avant la suppression. Après, les lignes `file` sont déjà parties en cascade et
    // le chiffre serait invariablement zéro — l'erreur que ce contrôle existe pour attraper.
    swept = try await store.sweepFolders(generation: generation)
    assert(swept == 0, "rien à balayer deux fois — obtenu \(swept)")

    print("ok — balayage : ce qui disparaît est compté avant la cascade, "
        + "et les arrivées d'une passe se distinguent par leur horodatage")
}
