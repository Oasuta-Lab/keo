import Foundation

/// The widget reads files and nothing else, so two things have to stay right: the shape of
/// the manifest it decodes, and which twelve photos a pinned folder offers it.
func checkWidget() async throws {
    // MARK: Le manifeste

    let manifest = WidgetManifest(
        version: WidgetManifest.currentVersion,
        stamped: Date(timeIntervalSince1970: 1_700_000_000),
        folders: [.init(path: "/NAS/Photos/2024", name: "2024", images: ["aa", "bb"],
                        mediaCount: 412, span: "2019 – 2024"),
                  // Un dossier pas encore entièrement indexé : le compte est inconnu, et le
                  // widget doit l'omettre plutôt que d'afficher zéro.
                  .init(path: "/NAS/Photos/Brut", name: "Brut", images: ["cc"],
                        mediaCount: nil, span: nil)],
        onThisDay: .init(images: ["d1", "d2"], years: [2016, 2009],
                         label: "25 octobre", total: 23)
    )
    let decoded = try JSONDecoder().decode(WidgetManifest.self,
                                           from: JSONEncoder().encode(manifest))
    assert(decoded.version == WidgetManifest.currentVersion)
    assert(decoded.stamped == manifest.stamped)
    assert(decoded.folders.map(\.path) == ["/NAS/Photos/2024", "/NAS/Photos/Brut"],
           "le chemin est l'identité que l'intent de configuration retient")
    assert(decoded.folders[0].name == "2024")
    assert(decoded.folders[0].images == ["aa", "bb"], "l'ordre des images est la sélection")
    assert(decoded.folders[0].mediaCount == 412 && decoded.folders[0].span == "2019 – 2024",
           "le contexte affiché à côté du nom")
    assert(decoded.folders[1].mediaCount == nil && decoded.folders[1].span == nil,
           "inconnu reste inconnu : un zéro se lirait « ce dossier est vide »")
    assert(decoded.onThisDay?.years == [2016, 2009],
           "les années accompagnent les images, dans le même ordre")
    assert(decoded.onThisDay?.total == 23 && decoded.onThisDay?.label == "25 octobre")

    // Une version antérieure doit être refusée, pas décodée de travers.
    assert(WidgetManifest.currentVersion == 2, "la version suit la forme du manifeste")

    // Un nom de fichier du NAS ne peut pas sortir du conteneur une fois haché.
    let traversal = WidgetManifest.key(for: "/NAS/../../etc/passwd")
    assert(traversal.count == 64 && !traversal.contains("/") && !traversal.contains("."),
           "un chemin devient un nom plat — \(traversal)")
    assert(WidgetManifest.key(for: "/a") != WidgetManifest.key(for: "/b"))
    assert(WidgetManifest.key(for: "/a") == WidgetManifest.key(for: "/a"),
           "stable d'un rendu à l'autre, sinon chaque passage réécrirait tout")

    // MARK: La sélection des douze, contre le vrai SQLite

    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-widget-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = IndexStore(directory: home)
    let pinned = "/NAS/Photos"

    func media(_ name: String, in folder: String, mime: String) -> Item {
        Item(path: "\(folder)/\(name)", name: name, isDirectory: false, size: 1_000,
             modified: nil, mimeType: mime)
    }
    func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    let generation = try await store.beginGeneration()

    // Dix photos dans un sous-dossier, les plus récentes.
    let recent = (1...10).map {
        (media("a\($0).jpg", in: pinned + "/2024", mime: "image/jpeg"), Optional(day(100 + $0)))
    }
    try await store.commit(recent, in: pinned + "/2024", generation: generation)

    // Dans un autre sous-dossier : une vieille photo, une sans date, une vidéo très récente
    // et un document. Les deux derniers ne sont pas des couvertures au même titre.
    try await store.commit([
        (media("b1.jpg", in: pinned + "/2023", mime: "image/jpeg"), day(1)),
        (media("sansdate.jpg", in: pinned + "/2023", mime: "image/jpeg"), nil),
        (media("clip.mp4", in: pinned + "/2023", mime: "video/mp4"), day(999)),
        (media("notes.pdf", in: pinned + "/2023", mime: "application/pdf"), day(999)),
    ], in: pinned + "/2023", generation: generation)

    // Un voisin dont le chemin commence par les mêmes lettres : il ne doit pas entrer.
    try await store.commit([(media("x.jpg", in: "/NAS/PhotosBis", mime: "image/jpeg"), day(500))],
                           in: "/NAS/PhotosBis", generation: generation)

    let covers = try await store.recentMedia(under: pinned, limit: 12)
    assert(covers.count == 12, "douze au plus — \(covers.count)")
    assert(covers.map(\.name)
        == (1...10).reversed().map { "a\($0).jpg" } + ["b1.jpg", "sansdate.jpg"],
           "les plus récentes d'abord, tout le sous-arbre confondu, les sans-date en bouche-trou "
         + "— \(covers.map(\.name))")
    assert(!covers.contains { $0.name == "notes.pdf" }, "un PDF n'est pas une couverture")
    assert(!covers.contains { $0.path.hasPrefix("/NAS/PhotosBis") },
           "le préfixe s'arrête à une frontière de dossier, sinon un voisin s'inviterait")
    assert(covers[0].captureDate == day(110), "la date que l'index connaît est reprise")
    assert(covers[0].path == pinned + "/2024/a10.jpg", "le chemin complet, pour le rendu")
    assert(covers[0].kind == .image)

    let wider = try await store.recentMedia(under: pinned, limit: 13)
    assert(wider.last?.name == "clip.mp4",
           "les vidéos passent après les photos quelle que soit leur date : une image de vidéo "
         + "coûte un passage d'AVAssetImageGenerator — \(wider.last?.name ?? "rien")")

    let unknown = try await store.recentMedia(under: "/NAS/Jamais vu", limit: 12)
    assert(unknown.isEmpty, "un dossier inconnu ne rend rien plutôt que tout")

    // MARK: L'étranglement

    var claimed = try await store.claimWidgetRender(signature: pinned, interval: 3_600)
    assert(claimed, "le premier rendu part tout de suite")
    claimed = try await store.claimWidgetRender(signature: pinned, interval: 3_600)
    assert(!claimed, "deux passages au premier plan d'affilée ne rendent pas deux fois")
    claimed = try await store.claimWidgetRender(signature: pinned + "\n/NAS/Vidéos",
                                                interval: 3_600)
    assert(claimed, "épingler un dossier ne doit pas attendre une heure pour s'afficher")
    claimed = try await store.claimWidgetRender(signature: pinned + "\n/NAS/Vidéos", interval: 0)
    assert(claimed, "l'intervalle écoulé, on rend à nouveau")

    print("ok — widget : manifeste, chemins aplatis, sélection des douze, étranglement")
}
