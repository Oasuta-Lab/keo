import Foundation

/// Un widget dont le tap ouvre la racine du NAS ressemble à un widget qui marche : c'est
/// exactement le genre d'erreur qui ne se voit pas. L'aller-retour est donc épinglé des deux
/// côtés — l'URL est fabriquée par `WidgetManifest`, relue par `DeepLink`.
func checkDeepLinks() {
    // --- aller-retour sur un dossier --------------------------------------------------------
    let path = "/NAS/Perso/Photos/Été 2024 & co"
    guard let url = WidgetManifest.link(folder: path) else {
        assertionFailure("l'URL de dossier n'a pas été fabriquée")
        return
    }
    assert(DeepLink(url) == .folder(path: path),
           "un chemin avec accents, espaces et esperluette doit revenir intact — \(url)")

    // --- aller-retour sur un jour -----------------------------------------------------------
    let day = Date(timeIntervalSince1970: 1_729_850_000)
    guard let dayURL = WidgetManifest.link(day: day) else {
        assertionFailure("l'URL de jour n'a pas été fabriquée")
        return
    }
    if case .day(let parsed) = DeepLink(dayURL) {
        assert(abs(parsed.timeIntervalSince1970 - day.timeIntervalSince1970) < 1,
               "le jour revient à la seconde près — \(parsed)")
    } else {
        assertionFailure("l'URL de jour ne s'est pas relue : \(dayURL)")
    }

    // --- les statistiques, sans paramètre -----------------------------------------------------
    guard let statsURL = WidgetManifest.statistics else {
        assertionFailure("l'URL des statistiques n'a pas été fabriquée")
        return
    }
    assert(statsURL.absoluteString == "keo://stats", "obtenu \(statsURL.absoluteString)")
    assert(DeepLink(statsURL) == .statistics,
           "le widget de couverture n'a qu'une destination, et c'est l'écran qui imprime "
         + "les réserves qu'il ne peut pas porter — \(statsURL)")

    // --- ce qui doit être refusé --------------------------------------------------------------
    assert(DeepLink(URL(string: "https://example.com/folder?path=/x")!) == nil,
           "un autre schéma n'ouvre rien")
    assert(DeepLink(URL(string: "keo://autre?path=/x")!) == nil, "un hôte inconnu n'ouvre rien")
    assert(DeepLink(URL(string: "keo://folder")!) == nil, "sans chemin, rien")
    assert(DeepLink(URL(string: "keo://folder?path=")!) == nil, "chemin vide, rien")
    assert(DeepLink(URL(string: "keo://folder?path=Perso/Photos")!) == nil,
           "un chemin relatif n'a pas de sens ici, et ouvrirait la racine sous un autre nom")
    assert(DeepLink(URL(string: "keo://day?stamp=hier")!) == nil, "une date illisible, rien")
    assert(DeepLink(URL(string: "keo://day")!) == nil, "sans date, rien")
    assert(DeepLink(URL(string: "https://example.com/stats")!) == nil,
           "les statistiques non plus ne s'ouvrent pas depuis le web")

    // --- le titre affiché en haut de l'écran ---------------------------------------------------
    assert(DeepLink.title(for: "/NAS/Perso/Photos") == "Photos")
    assert(DeepLink.title(for: "/") == nil, "« / » serait un mauvais titre d'écran")

    print("ok — liens profonds : aller-retour, chemins exotiques, et tout ce qui est refusé")
}


/// Un fil d'Ariane qui se trompe d'un cran renvoie dans le mauvais dossier — et sur un NAS,
/// « le mauvais dossier » peut être à côté de quinze mille photos.
func checkBreadcrumb() {
    let trail = Breadcrumb.trail(to: "/NAS/Perso/Photos/Été 2024", rootName: "Freebox")
    assert(trail.map(\.name) == ["Freebox", "NAS", "Perso", "Photos", "Été 2024"],
           "la racine d'abord, le dossier courant en dernier — \(trail.map(\.name))")
    assert(trail.map(\.path) == ["/", "/NAS", "/NAS/Perso", "/NAS/Perso/Photos",
                                 "/NAS/Perso/Photos/Été 2024"],
           "chaque miette porte son chemin complet — \(trail.map(\.path))")

    let root = Breadcrumb.trail(to: "/", rootName: "Freebox")
    assert(root.map(\.name) == ["Freebox"], "à la racine, une seule miette — \(root.map(\.name))")

    assert(Breadcrumb.trail(to: "", rootName: "Freebox").isEmpty,
           "un favori ou une collection n'a pas de chemin à remonter")

    let spaced = Breadcrumb.trail(to: "/NAS/Job Life/Projets dev", rootName: "Freebox")
    assert(spaced.last?.path == "/NAS/Job Life/Projets dev",
           "les espaces ne coupent pas un chemin — \(spaced.last?.path ?? "")")

    print("ok — fil d'Ariane : racine, profondeur, accents, espaces, et les sources sans chemin")
}
