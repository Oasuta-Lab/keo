import Foundation

/// La règle d'exclusion décide de ce que Keo ne regarde pas. Une erreur dans un sens coûte
/// quelques requêtes inutiles ; une erreur dans l'autre, ce sont des photos que le propriétaire
/// ne retrouvera jamais, sans le moindre message. Les deux sens sont donc épinglés ici, et le
/// nettoyage de l'index déjà écrit est exercé contre le vrai SQLite.
func checkFolderExclusion() async throws {
    // --- ce qui est exclu ---------------------------------------------------------------
    assert(FolderExclusion.excludes(folder: "node_modules"), "la raison d'être de la règle")
    assert(FolderExclusion.excludes(folder: "__pycache__"))
    assert(FolderExclusion.excludes(folder: "@eaDir"), "la réserve de vignettes de Synology")
    assert(FolderExclusion.excludes(folder: "#recycle"), "la corbeille de Synology")
    assert(FolderExclusion.excludes(folder: "lost+found"))

    // --- la casse ne protège rien --------------------------------------------------------
    // Un partage SMB est insensible à la casse : `NODE_MODULES` et `node_modules` désignent
    // le même répertoire, et la règle doit les voir pareil.
    assert(FolderExclusion.excludes(folder: "NODE_MODULES"))
    assert(FolderExclusion.excludes(folder: "Node_Modules"))
    assert(FolderExclusion.excludes(folder: "@EADIR"))
    assert(FolderExclusion.excludes(folder: "System Volume Information"))
    assert(FolderExclusion.excludes(folder: "system volume information"))

    // --- les noms pointés -----------------------------------------------------------------
    // `FreeboxClient.listPage` les écarte déjà avant que la règle soit consultée : `.github`
    // est donc invisible pour Keo de toute façon, et le dire ici aussi n'enlève rien de plus.
    // Ce que ça apporte : le nettoyage ci-dessous atteint les lignes qu'un ancien build a pu
    // écrire, et la règle reste la seule réponse à « Keo indexe-t-il ce dossier ? ».
    assert(FolderExclusion.excludes(folder: ".git"))
    assert(FolderExclusion.excludes(folder: ".venv"))
    assert(FolderExclusion.excludes(folder: ".Trash"))
    assert(FolderExclusion.excludes(folder: ".Spotlight-V100"))
    assert(FolderExclusion.excludes(folder: ".github"),
           "déjà écarté par le listing de la box ; la règle en dit autant, pas moins")

    // --- ce qui ne doit SURTOUT pas être exclu ---------------------------------------------
    // Décision épinglée : `build`, `dist`, `target`, `vendor` et `Pods` restent indexés. Ce
    // sont des mots ordinaires — « Build » peut être un dossier de chantier photographié, et
    // perdre ces photos en silence coûte infiniment plus cher que de lister un répertoire
    // d'artefacts, qui pèse de toute façon mille fois moins qu'un `node_modules`.
    for innocent in ["build", "Build", "dist", "target", "vendor", "Vendor", "Pods",
                     "Photos", "2024", "Vacances", "Projets", "Documents"] {
        assert(!FolderExclusion.excludes(folder: innocent),
               "« \(innocent) » doit rester indexé : c'est peut-être un dossier de photos")
    }

    // La correspondance est exacte, jamais un sous-texte : un dossier dont le nom contient
    // « node_modules » n'est pas un `node_modules`.
    assert(!FolderExclusion.excludes(folder: "node_modules copie"))
    assert(!FolderExclusion.excludes(folder: "mon-node_modules"))
    assert(!FolderExclusion.excludes(folder: "node modules"), "avec une espace, c'est autre chose")
    assert(!FolderExclusion.excludes(folder: "venv2"))

    // --- la règle sur un chemin entier ------------------------------------------------------
    assert(FolderExclusion.excludes(path: "/NAS/Projets/app/node_modules"))
    assert(FolderExclusion.excludes(path: "/NAS/Projets/app/node_modules/react/dist"),
           "un composant exclu emporte tout ce qui est dessous")
    assert(FolderExclusion.excludes(path: "/NAS/Photos/@eaDir/2024"))
    assert(!FolderExclusion.excludes(path: "/NAS/Photos/2024/Vacances"))
    assert(!FolderExclusion.excludes(path: "/"), "la racine n'est pas exclue d'elle-même")
    assert(!FolderExclusion.excludes(path: ""))

    // --- le nettoyage de ce qui est déjà indexé ----------------------------------------------
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-exclusions-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func file(_ name: String, in folder: String) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: 1_024,
             modified: nil, mimeType: name.hasSuffix(".jpg") ? "image/jpeg" : nil)
    }

    let store = IndexStore(directory: home)
    let album = "/NAS/Photos/2024"
    let junk = "/NAS/Projets/app/node_modules"
    let deeper = "/NAS/Projets/app/node_modules/react/dist"
    let project = "/NAS/Projets/app"

    let keeper = file("plage.jpg", in: album)
    let buried = file("README.md", in: junk)
    let deepest = file("index.js", in: deeper)
    let source = file("main.swift", in: project)

    let generation = try await store.beginGeneration()
    try await store.commit([(keeper, Date(timeIntervalSince1970: 1_600_000_000))],
                           in: album, generation: generation)
    try await store.commit([(buried, nil)], in: junk, generation: generation)
    try await store.commit([(deepest, nil)], in: deeper, generation: generation)
    try await store.commit([(source, nil)], in: project, generation: generation)

    // Les trois formes de personnalisation, dont une posée *à l'intérieur* du dossier exclu :
    // elles sont clavetées sur le chemin et survivent à l'index, jamais l'inverse.
    try await store.setFavourite([keeper, buried], true)
    try await store.setNote("à garder", on: buried)
    try await store.setShortcut(Item(path: junk, name: "node_modules", isDirectory: true,
                                     size: 0, modified: nil, mimeType: "inode/directory"), true)
    let collection = try await store.createCollection(named: "Été")
    try await store.setMembership([keeper, buried], in: collection, true)

    let before = try await store.fileCount()
    assert(before == 4, "quatre fichiers indexés avant le nettoyage — \(before)")

    try await store.replayExclusionCleanupForChecks()

    let after = try await store.fileCount()
    assert(after == 2, "il ne doit rester que la photo et le fichier source — \(after)")

    let leftInJunk = try await store.listing(junk)
    let leftDeeper = try await store.listing(deeper)
    let leftInAlbum = try await store.listing(album).map(\.name)
    let leftInProject = try await store.listing(project).map(\.name)
    assert(leftInJunk.isEmpty, "le dossier exclu n'a plus de ligne")
    assert(leftDeeper.isEmpty, "ni son sous-arbre, par cascade")
    assert(leftInAlbum == ["plage.jpg"], "les photos d'à côté ne sont pas touchées")
    assert(leftInProject == ["main.swift"],
           "le projet lui-même reste indexé : seul le répertoire technique part")

    // --- et ce que le nettoyage ne touche provablement pas ------------------------------------
    let favourites = try await store.favourites().map(\.path).sorted()
    assert(favourites == [buried.path, keeper.path].sorted(),
           "les favoris survivent, y compris celui pointant dans le dossier exclu — \(favourites)")
    let survivingNote = try await store.note(on: buried)
    let survivingShortcuts = try await store.shortcuts().map(\.path)
    let members = try await store.items(in: collection).map(\.path).sorted()
    assert(survivingNote == "à garder", "la note survit aussi")
    assert(survivingShortcuts == [junk],
           "le raccourci vers le dossier exclu reste : c'est le propriétaire qui l'a posé")
    assert(members == [buried.path, keeper.path].sorted(),
           "la collection garde ses deux membres")

    // Rejouer le nettoyage ne doit rien casser de plus : c'est une passe idempotente.
    try await store.replayExclusionCleanupForChecks()
    let stillThere = try await store.fileCount()
    let stillFavourite = try await store.favouriteCount()
    assert(stillThere == 2, "un second passage n'enlève rien de plus — \(stillThere)")
    assert(stillFavourite == 2, "ni ne touche aux favoris — \(stillFavourite)")

    print("ok — exclusion des dossiers techniques, casse, chemins, nettoyage de l'index")
}
