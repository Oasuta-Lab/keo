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

    // Le cache rend tout, y compris le compagnon : c'est `FolderContents` qui masque, et
    // c'est le même code qui masque dans un listing frais venu de la box. Un dossier ouvert
    // depuis le cache montre donc exactement ce qu'il montrera après la réponse de la box.
    let cached = try await store.listing(folder)
    assert(cached.map(\.name).sorted()
           == ["IMG_4821.HEIC", "IMG_4821.MOV", "IMG_9999.HEIC", "Vacances.MOV"],
           "le cache rend tout — \(cached.map(\.name))")

    let painted = FolderContents(cached)
    assert(painted.media.map(\.name).sorted()
           == ["IMG_4821.HEIC", "IMG_9999.HEIC", "Vacances.MOV"],
           "et la grille applique la règle — \(painted.media.map(\.name))")
    assert(painted.companion(of: still)?.name == "IMG_4821.MOV",
           "la pastille « live » et la lecture marchent donc aussi depuis le cache")

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
    let orphan = FolderContents(try await store.listing(folder))
    assert(orphan.media.map(\.name) == ["IMG_4821.MOV"],
           "sans sa photo, la vidéo redevient visible plutôt que de disparaître — "
           + "\(orphan.media.map(\.name))")
    assert(orphan.companions.isEmpty, "et plus rien n'est apparié")

    print("ok — photos live : appariement, .MOV isolé, cache, recherche, et retour en arrière")
}

/// L'identité d'Apple contre la coïncidence de nom. C'est le cas signalé par l'usage : deux
/// IMG_0988 sans aucun rapport, fondus en un seul moment parce qu'ils portaient le même nom.
func checkLiveIdentity() async throws {
    func photo(_ name: String, cid: String?, date: Date? = nil) -> Item {
        var item = Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false,
                        size: 3_000, modified: nil, mimeType: "image/heic", captureDate: date)
        item.contentID = cid
        return item
    }
    func clip(_ name: String, cid: String?, date: Date? = nil) -> Item {
        var item = Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false,
                        size: 2_000, modified: nil, mimeType: "video/quicktime",
                        captureDate: date)
        item.contentID = cid
        return item
    }

    let uuid = "B0C8F762-32B9-4024-AA39-B1B94E631148"
    let other = "11111111-2222-3333-4444-555555555555"

    // --- la matrice, en pur -----------------------------------------------------------------
    assert(LivePhotos.compatible(still: photo("a.heic", cid: uuid),
                                 video: clip("a.mov", cid: uuid)),
           "mêmes identifiants : c'est une paire")
    assert(!LivePhotos.compatible(still: photo("a.heic", cid: uuid),
                                  video: clip("a.mov", cid: other)),
           "identifiants différents : le cas IMG_0988, ce n'est pas une paire")
    assert(LivePhotos.compatible(still: photo("a.heic", cid: nil),
                                 video: clip("a.mov", cid: uuid)),
           "photo jamais lue : la règle du nom reste en charge, rien ne régresse")
    assert(LivePhotos.compatible(still: photo("a.heic", cid: uuid),
                                 video: clip("a.mov", cid: nil)),
           "vidéo jamais lue : idem")
    assert(LivePhotos.compatible(still: photo("a.heic", cid: uuid),
                                 video: clip("a.mov", cid: "")),
           "vidéo lue sans identifiant et sans dates comparables : on ne dé-apparie pas "
           + "sur un silence")
    assert(LivePhotos.compatible(still: photo("a.heic", cid: ""),
                                 video: clip("a.mov", cid: "")),
           "aucun des deux : deux fichiers ordinaires, la règle du nom décide")

    // --- une seule face porteuse : les dates départagent ------------------------------------
    // Le cas réel : IMG_0985.JPEG lue sans identifiant, IMG_0985.MOV qui en porte un. Soit la
    // photo a été ré-encodée et la paire est vraie (les deux moitiés sont écrites à quelques
    // secondes près), soit la vraie moitié est ailleurs et la vidéo est un film à part.
    let shot = Date(timeIntervalSince1970: 1_600_000_000)
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: shot),
                                 video: clip("b.mov", cid: uuid, date: shot.addingTimeInterval(2))),
           "dates à deux secondes : une photo ré-encodée, la paire est vraie")
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: shot),
                                 video: clip("b.mov", cid: uuid,
                                             date: shot.addingTimeInterval(-9 * 3600))),
           "neuf heures d'écart : l'EXIF est naïf, la vidéo porte son fuseau — une paire "
           + "prise à l'étranger a le droit à cet écart")
    assert(!LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: shot),
                                  video: clip("b.mov", cid: uuid,
                                              date: shot.addingTimeInterval(-86_400 * 400))),
           "plus d'un an d'écart : la vraie moitié est ailleurs, la vidéo redevient visible")
    assert(!LivePhotos.compatible(still: photo("b.jpeg", cid: uuid, date: shot),
                                  video: clip("b.mov", cid: "",
                                              date: shot.addingTimeInterval(86_400 * 400))),
           "le cas symétrique — vidéo lue sans identifiant — se juge pareil")
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: shot),
                                 video: clip("b.mov", cid: uuid, date: nil)),
           "date vidéo encore inconnue : masquer à tort perd une vidéo, la paire tient "
           + "jusqu'à la lecture")
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: nil),
                                 video: clip("b.mov", cid: uuid, date: shot)),
           "date photo inconnue : même prudence")
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: uuid, date: shot),
                                 video: clip("b.mov", cid: uuid,
                                             date: shot.addingTimeInterval(-86_400 * 400))),
           "deux identifiants égaux : l'identité l'emporte, les dates n'ont rien à redire")
    assert(LivePhotos.compatible(still: photo("b.jpeg", cid: "", date: shot),
                                 video: clip("b.mov", cid: "",
                                             date: shot.addingTimeInterval(-86_400 * 400))),
           "aucun identifiant nulle part : la règle du nom reste seule en charge")

    // --- deux moments, un seul nom ------------------------------------------------------------
    let mine = photo("IMG_0988.HEIC", cid: uuid)
    let stranger = clip("IMG_0988.MOV", cid: other)
    let (visible, companions) = LivePhotos.pair([mine, stranger])
    assert(visible.map(\.name).sorted() == ["IMG_0988.HEIC", "IMG_0988.MOV"],
           "la vidéo étrangère reste visible — \(visible.map(\.name))")
    assert(companions.isEmpty, "et rien n'est apparié")

    // La bonne vidéo trouve sa photo même quand une homonyme s'intercale.
    let real = clip("IMG_0988.MOV", cid: uuid)
    let both = LivePhotos.pair([mine, photo("IMG_0988.HEIC", cid: other), real])
    assert(both.companions[mine.id]?.contentID == uuid,
           "la vidéo rejoint la photo qui porte son identifiant, pas la première venue")

    // --- la même règle, côté SQLite -------------------------------------------------------------
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-identite-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = IndexStore(directory: home)
    let folder = "/NAS/Photos"
    let generation = try await store.beginGeneration()
    try await store.commit([(mine, nil), (stranger, nil)], in: folder, generation: generation)
    try await store.markLivePairs(in: folder)

    let listed = FolderContents(try await store.listing(folder))
    assert(listed.media.map(\.name).sorted() == ["IMG_0988.HEIC", "IMG_0988.MOV"],
           "le SQL dit la même chose que Swift — \(listed.media.map(\.name))")
    let found = try await store.companion(of: mine, in: folder)
    assert(found == nil, "et la visionneuse n'a pas de vidéo à jouer")

    // La vraie paire, elle, reste appariée.
    let gen2 = try await store.beginGeneration()
    try await store.commit([(mine, nil), (real, nil)], in: folder, generation: gen2,
                           present: [mine, real], sweep: true)
    try await store.markLivePairs(in: folder)
    let paired = FolderContents(try await store.listing(folder))
    assert(paired.media.map(\.name) == ["IMG_0988.HEIC"],
           "une vraie paire reste un seul moment — \(paired.media.map(\.name))")

    // --- la règle des dates, côté SQLite ------------------------------------------------------
    // Le cas réel d'IMG_0985 : la photo lue sans identifiant, la vidéo porteuse. Les dates
    // tranchent, et le même verdict doit sortir du SQL, du cache rejoué et du Swift pur.
    let faces = "/NAS/Une face"
    func committed(_ name: String, cid: String?, date: Date?, video: Bool = false) -> Item {
        var item = Item(path: faces + "/" + name, name: name, isDirectory: false,
                        size: video ? 2_000 : 3_000, modified: nil,
                        mimeType: video ? "video/quicktime" : "image/jpeg", captureDate: date)
        item.contentID = cid
        return item
    }
    let far = committed("IMG_0985.JPEG", cid: "", date: shot)
    let farClip = committed("IMG_0985.MOV", cid: uuid,
                            date: shot.addingTimeInterval(-86_400 * 400), video: true)
    let near = committed("IMG_0986.JPEG", cid: "", date: shot)
    let nearClip = committed("IMG_0986.MOV", cid: uuid,
                             date: shot.addingTimeInterval(2), video: true)
    let blind = committed("IMG_0987.JPEG", cid: "", date: shot)
    let blindClip = committed("IMG_0987.MOV", cid: uuid, date: nil, video: true)

    let gen3 = try await store.beginGeneration()
    try await store.commit([(far, far.captureDate), (farClip, farClip.captureDate),
                            (near, near.captureDate), (nearClip, nearClip.captureDate),
                            (blind, blind.captureDate), (blindClip, nil)],
                           in: faces, generation: gen3)
    try await store.markLivePairs(in: faces)

    let judged = FolderContents(try await store.listing(faces))
    assert(judged.media.map(\.name).sorted() == ["IMG_0985.JPEG", "IMG_0985.MOV",
                                                 "IMG_0986.JPEG", "IMG_0987.JPEG"],
           "un an d'écart dé-apparie, deux secondes gardent, une date absente garde — "
           + "\(judged.media.map(\.name).sorted())")
    let farCompanion = try await store.companion(of: far, in: faces)
    assert(farCompanion == nil, "la vidéo dé-appariée n'est plus proposée à la visionneuse")
    let nearCompanion = try await store.companion(of: near, in: faces)
    assert(nearCompanion?.name == "IMG_0986.MOV", "la paire ré-encodée joue toujours sa vidéo")

    // La population que le banc « uneface » juge : les paires à une seule face porteuse.
    let oneSided = try await store.oneSidedPairs()
    assert(oneSided.filter { $0.folder == faces }.map(\.video.name).sorted()
           == ["IMG_0985.MOV", "IMG_0986.MOV", "IMG_0987.MOV"],
           "le banc voit les trois, verdicts compris — "
           + "\(oneSided.filter { $0.folder == faces }.map(\.video.name))")

    print("ok — identité des photos live : accord, contradiction, silence, les dates qui "
        + "départagent les faces uniques, et le même verdict en SQL qu'en Swift")
}
