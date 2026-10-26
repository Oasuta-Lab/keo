import Foundation
import SQLite3

/// À qui la sonde de 256 Ko a le droit de servir de vignette.
///
/// Le piège vérifié ici a été mesuré, pas supposé : ImageIO fabrique une vignette à partir
/// d'un PNG tronqué sans le dire — bonne taille, bon rapport d'aspect, et 100 % de pixels
/// transparents. `accepts` ne regarde que la taille et le rapport, donc elle la prenait, la
/// cellule gardait un vide en cache, et le repli qui télécharge le fichier entier — celui qui
/// aurait marché — ne se déclenchait jamais.
func checkPreviewProbeTrust() {
    let probe = 256 << 10
    let big: Int64 = 20 << 20
    let small: Int64 = 100 << 10

    // --- les formats qui portent vraiment une vignette ---------------------------------
    for name in ["photo.jpg", "photo.JPEG", "sortie.heic", "scan.tiff",
                 "brut.dng", "canon.CR3", "nikon.nef", "sony.arw"] {
        assert(PreviewPolicy.trustsProbe(path: "/NAS/\(name)", size: big, probeBytes: probe),
               "\(name) embarque un aperçu avant ses pixels, la sonde suffit")
    }

    // --- ceux qui n'en portent pas : la sonde ne peut rien contenir d'utile -------------
    for name in ["capture.png", "animation.gif", "vieux.bmp", "moderne.webp"] {
        assert(!PreviewPolicy.trustsProbe(path: "/NAS/\(name)", size: big, probeBytes: probe),
               "\(name) n'a pas d'aperçu intégré : croire la sonde rendrait une image vide")
    }

    // --- sauf si le fichier tient entièrement dans la sonde -----------------------------
    assert(PreviewPolicy.trustsProbe(path: "/NAS/petite.png", size: small, probeBytes: probe),
           "un PNG plus petit que la sonde n'est pas tronqué : il n'y a rien à rater")
    assert(PreviewPolicy.trustsProbe(path: "/NAS/pile.png", size: Int64(probe), probeBytes: probe),
           "à la taille exacte de la sonde, le fichier est entier")
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/juste.png", size: Int64(probe) + 1,
                                      probeBytes: probe),
           "un octet de plus et le fichier est tronqué")

    // --- la casse de l'extension ne doit pas décider ------------------------------------
    assert(PreviewPolicy.trustsProbe(path: "/NAS/A/B.JPG", size: big, probeBytes: probe),
           "l'extension se compare en minuscules")
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/sans extension", size: big, probeBytes: probe),
           "sans extension, on ne parie pas")

    // --- un chemin qui contient « .jpg » ailleurs que dans l'extension ------------------
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/exports.jpg/final.png", size: big,
                                      probeBytes: probe),
           "c'est l'extension du fichier qui compte, pas un dossier qui porte ce nom")

    // --- la clé de cache doit retirer les vignettes vides déjà écrites -----------------
    // Corriger le rendu ne suffisait pas : les vides étaient déjà sur le disque, et ce
    // dossier survit à une réinstallation. Changer de route change la clé.
    let plain = DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400)
    let full = DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400, variant: "full")
    assert(plain != full, "une route différente doit donner une clé différente")
    assert(plain == DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400, variant: ""),
           "une variante vide ne doit pas déplacer les clés déjà écrites")
    assert(DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400)
           != DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 200),
           "la taille demandée fait toujours partie de la clé")

    print("ok — la sonde n'est crue que là où elle peut contenir un aperçu, "
        + "et la route choisie fait partie de la clé")
}

/// La règle de pluriel française, maintenant unique dans le projet.
///
/// Elle a dérivé une fois : l'app appliquait `n > 1`, le widget `n == 1 ? "" : "s"`, et
/// affichait « 0 photos ». Zéro est singulier en français.
func checkFrenchPlural() {
    assert(Plural.count(0, "élément", "éléments") == "0 élément", "zéro est singulier")
    assert(Plural.count(1, "élément", "éléments") == "1 élément", "un est singulier")
    assert(Plural.count(2, "élément", "éléments") == "2 éléments", "deux est pluriel")
    assert(Plural.count(8_380, "élément", "éléments").hasSuffix(" éléments"),
           "les milliers restent pluriels")
    // Le séparateur de milliers vient de la locale, donc on ne le compare pas à un littéral :
    // on vérifie seulement que le nombre a été formaté et non interpolé brut.
    assert(Plural.count(8_380, "é", "é") != "8380 é", "le nombre passe par formatted()")
    print("ok — pluriel français : zéro et un au singulier, et les milliers formatés")
}

/// L'étagère de l'accueil s'appelle « Dernières photos » : elle ne doit rendre que des photos.
///
/// Le filtre est une liste de genres interpolée dans du SQL, donc une liste vide ou mal
/// composée ne se verrait qu'à l'écran — sur un vrai SQLite, comme le reste du magasin.
func checkRecentKinds() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-recent-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func file(_ name: String) -> Item {
        Item(path: "/NAS/Mix/\(name)", name: name, isDirectory: false, size: 2_048,
             modified: nil, mimeType: nil)
    }
    let store = IndexStore(directory: home)
    let generation = try await store.beginGeneration()
    let day = Date(timeIntervalSince1970: 1_600_000_000)
    try await store.commit([
        (file("a.jpg"), day), (file("b.png"), day),
        (file("film.mov"), day), (file("notes.txt"), day),
    ], in: "/NAS/Mix", generation: generation)

    let photos = try await store.recentMedia(under: "/NAS/Mix", limit: 12, kinds: [.image])
    assert(photos.allSatisfy { $0.kind == .image },
           "« Dernières photos » ne doit ramener que des images — \(photos.map(\.name))")
    assert(Set(photos.map(\.name)) == ["a.jpg", "b.png"],
           "les deux images, et rien d'autre — \(photos.map(\.name))")

    let media = try await store.recentMedia(under: "/NAS/Mix", limit: 12)
    assert(media.contains { $0.kind == .video },
           "par défaut le widget prend aussi les vidéos")
    assert(!media.contains { $0.kind == .other },
           "un document n'est jamais un média")

    print("ok — l'étagère « Dernières photos » ne ramène que des photos")
}

/// La date d'arrivée : jamais inventée, posée une fois, jamais déplacée.
///
/// Quatre propriétés, et chacune s'est payée. La plus coûteuse à voir est la première : la
/// table étant vide à la livraison, le premier passage sur un dossier tamponnait tout son
/// contenu comme arrivé à l'instant — des fichiers posés là depuis des années. Un fichier
/// n'est une arrivée que s'il apparaît dans un dossier que Keo connaissait déjà.
func checkArrivalDate() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-added-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func file(_ name: String, size: Int64 = 2_048) -> Item {
        Item(path: "/NAS/Boîte/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: nil)
    }
    let store = IndexStore(directory: home)
    let folder = "/NAS/Boîte"
    let stamp = FolderStamp.Completion(modified: Date(timeIntervalSince1970: 1_700_000_000),
                                       childCount: 3, mediaCount: 1, bytes: 6_144)

    // --- premier passage : rien n'est une arrivée -------------------------------------
    var generation = try await store.beginGeneration()
    try await store.commit([(file("a.jpg"), nil)], in: folder, generation: generation,
                           stamp: stamp,
                           present: [file("a.jpg"), file("notes.txt"), file("clip.mov")])
    let first = try await store.recentlyAdded(under: folder, limit: 10)
    assert(first.isEmpty,
           "un dossier découvert n'est pas un dossier où quelque chose vient d'arriver — "
         + "\(first.map(\.name))")

    // --- deuxième passage : seul le nouveau est une arrivée ---------------------------
    try await Task.sleep(for: .milliseconds(1_100))
    generation = try await store.beginGeneration()
    try await store.commit([(file("a.jpg"), nil)], in: folder, generation: generation,
                           stamp: stamp,
                           present: [file("a.jpg"), file("notes.txt"), file("clip.mov"),
                                     file("neuf.pdf")])
    let second = try await store.recentlyAdded(under: folder, limit: 10)
    assert(second.map(\.name) == ["neuf.pdf"],
           "seul le fichier apparu depuis la dernière visite — \(second.map(\.name))")
    assert(second.first?.kind == .other,
           "un document est une arrivée comme une autre : c'est tout l'intérêt de l'étagère")

    // --- un troisième passage sans rien de neuf ne change rien ------------------------
    try await Task.sleep(for: .milliseconds(1_100))
    generation = try await store.beginGeneration()
    try await store.commit([(file("a.jpg"), nil)], in: folder, generation: generation,
                           stamp: stamp,
                           present: [file("a.jpg"), file("notes.txt"), file("clip.mov"),
                                     file("neuf.pdf")])
    let again = try await store.recentlyAdded(under: folder, limit: 10)
    assert(again.map(\.name) == ["neuf.pdf"],
           "repasser ne crée pas d'arrivées et ne déplace pas celles qui existent — "
         + "\(again.map(\.name))")

    // --- « Tout relire depuis zéro » non plus -----------------------------------------
    // Le cas qui a tué la première version : la reconstruction fait `DELETE FROM file`, donc
    // une date rangée dans cette table-là était effacée et tout remontait d'un coup.
    try await store.forgetEverything()
    try await Task.sleep(for: .milliseconds(1_100))
    generation = try await store.beginGeneration()
    try await store.commit([(file("a.jpg"), nil)], in: folder, generation: generation,
                           stamp: stamp,
                           present: [file("a.jpg"), file("notes.txt"), file("clip.mov"),
                                     file("neuf.pdf")])
    let rebuilt = try await store.recentlyAdded(under: folder, limit: 10)
    assert(rebuilt.map(\.name) == ["neuf.pdf"],
           "après une reconstruction, l'étagère est celle d'avant — \(rebuilt.map(\.name))")

    print("ok — arrivées : un dossier découvert n'en produit aucune, seul le neuf en est une, "
        + "et ni un repassage ni une reconstruction ne les déplacent")
}

/// Le compteur d'arrivées non vues.
///
/// Il compte des **arrivées**, pas des lectures. L'app a déjà « N fichiers à lire », qui ne
/// parle que des dates à aller chercher — un document n'en a aucune, il est complet dès qu'il
/// est listé, et l'y compter ferait promettre un travail inexistant à un voyant qui ne
/// s'éteindrait jamais.
func checkUnseenArrivals() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-unseen-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func file(_ name: String) -> Item {
        Item(path: "/NAS/Boîte/\(name)", name: name, isDirectory: false, size: 2_048,
             modified: nil, mimeType: nil)
    }
    let store = IndexStore(directory: home)
    let folder = "/NAS/Boîte"
    let stamp = FolderStamp.Completion(modified: Date(timeIntervalSince1970: 1_700_000_000),
                                       childCount: 2, mediaCount: 1, bytes: 4_096)

    // Premier passage : le dossier est découvert, donc rien n'est une arrivée.
    var generation = try await store.beginGeneration()
    try await store.commit([], in: folder, generation: generation, stamp: stamp,
                           present: [file("a.jpg")])
    var unseen = try await store.unseenArrivals()
    assert(unseen == 0, "un dossier découvert ne signale rien — \(unseen)")

    // Un document arrive : il compte, alors qu'il n'a aucune date à lire.
    try await Task.sleep(for: .milliseconds(1_100))
    generation = try await store.beginGeneration()
    try await store.commit([], in: folder, generation: generation, stamp: stamp,
                           present: [file("a.jpg"), file("facture.pdf")])
    unseen = try await store.unseenArrivals()
    assert(unseen == 1,
           "un document est une arrivée : c'est tout l'intérêt de ce compteur — \(unseen)")

    // Montrer l'étagère éteint le compteur.
    try await store.markArrivalsSeen()
    unseen = try await store.unseenArrivals()
    assert(unseen == 0, "une fois montrées, elles ne sont plus neuves — \(unseen)")

    // Et une arrivée postérieure au repère le rallume.
    try await Task.sleep(for: .milliseconds(1_100))
    generation = try await store.beginGeneration()
    try await store.commit([], in: folder, generation: generation, stamp: stamp,
                           present: [file("a.jpg"), file("facture.pdf"), file("plus.txt")])
    unseen = try await store.unseenArrivals()
    assert(unseen == 1,
           "ce qui arrive après le dernier regard compte à nouveau — \(unseen)")

    print("ok — arrivées non vues : un document compte, l'affichage éteint, la suite rallume")
}
