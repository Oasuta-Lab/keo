import Foundation

/// La même règle d'appariement doit tenir à trois endroits — un listing frais venu de la box,
/// un listing rejoué depuis l'index, et le SQL qui marque la base. Une règle qui dérive entre
/// les deux montre la vidéo d'un côté et la cache de l'autre.
func checkLivePhotos() async throws {
    // --- la règle, en pur ---------------------------------------------------------------
    assert(LivePhotos.stem("IMG_4821.HEIC") == "IMG_4821")
    assert(LivePhotos.stem("IMG_4821.MOV") == "IMG_4821")
    assert(LivePhotos.stem("sans-extension") == "sans-extension", "pas de point, pas de coupe")
    assert(LivePhotos.stem(".caché") == ".caché", "un nom qui commence par un point reste entier")
    assert(LivePhotos.stem("a.b.c") == "a.b", "seule la dernière extension tombe")
    assert(LivePhotos.key("IMG_4821.HEIC") == LivePhotos.key("img_4821.mov"),
           "un partage SMB est insensible à la casse")

    func photo(_ name: String) -> Item {
        Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false, size: 3_000,
             modified: nil, mimeType: "image/heic")
    }
    func clip(_ name: String) -> Item {
        Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false, size: 2_000,
             modified: nil, mimeType: "video/quicktime")
    }

    let still = photo("IMG_4821.HEIC")
    let live = clip("IMG_4821.MOV")
    let alone = clip("Vacances.MOV")
    let other = photo("IMG_9999.HEIC")

    let (visible, companions) = LivePhotos.pair([still, live, alone, other])
    assert(visible.map(\.name).sorted() == ["IMG_4821.HEIC", "IMG_9999.HEIC", "Vacances.MOV"],
           "le .MOV apparié disparaît, le .MOV seul reste — \(visible.map(\.name))")
    assert(companions[still.id]?.name == "IMG_4821.MOV", "et il est retrouvable depuis sa photo")
    assert(companions[other.id] == nil, "une photo sans vidéo n'en invente pas")

    // Un dossier sans aucune image : rien ne doit être masqué, surtout pas des vidéos.
    let onlyClips = LivePhotos.pair([alone, clip("Noel.MOV")])
    assert(onlyClips.visible.count == 2 && onlyClips.companions.isEmpty,
           "un dossier de vidéos reste un dossier de vidéos")

    // --- la même règle, côté SQLite -------------------------------------------------------
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-live-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = IndexStore(directory: home)
    let folder = "/NAS/Photos"
    let generation = try await store.beginGeneration()
    try await store.commit([(still, nil), (live, nil), (alone, nil), (other, nil)],
                           in: folder, generation: generation)
    try await store.markLivePairs(in: folder)

    let listed = try await store.listing(folder).map(\.name).sorted()
    assert(listed == ["IMG_4821.HEIC", "IMG_9999.HEIC", "Vacances.MOV"],
           "le cache cache exactement ce que la grille cache — \(listed)")

    let found = try await store.companion(of: still, in: folder)
    assert(found?.name == "IMG_4821.MOV", "la visionneuse retrouve la vidéo — \(found?.name ?? "rien")")
    assert(found?.kind == .video, "et c'est bien une vidéo")
    let nothing = try await store.companion(of: other, in: folder)
    assert(nothing == nil, "pas d'invention ici non plus")

    // La recherche ne doit pas rendre le compagnon : il porte le même nom que sa photo et
    // doublerait chaque résultat.
    let hits = try await store.search(SearchQuery(text: "IMG_4821"))
    assert(hits.map(\.name) == ["IMG_4821.HEIC"], "un seul résultat par moment — \(hits.map(\.name))")

    // --- le marquage est réversible ---------------------------------------------------------
    // Si la photo disparaît du dossier, son ancienne vidéo redevient une vidéo visible.
    let next = try await store.beginGeneration()
    try await store.commit([(live, nil)], in: folder, generation: next,
                           stamp: FolderStamp.Completion(modified: Date(), childCount: 1,
                                                         mediaCount: 1, bytes: 2_000),
                           present: [live], sweep: true)
    try await store.markLivePairs(in: folder)
    let orphan = try await store.listing(folder).map(\.name)
    assert(orphan == ["IMG_4821.MOV"],
           "sans sa photo, la vidéo redevient visible plutôt que de disparaître — \(orphan)")

    print("ok — photos live : appariement, .MOV isolé, cache, recherche, et retour en arrière")
}
