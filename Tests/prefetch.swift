import Foundation

/// La fenêtre de préchargement remplace, elle n'empile pas. C'est tout l'écart entre « les
/// vignettes arrivent » et « j'ai scrollé loin, la grille est vide » : une file qui ne faisait
/// que grossir servait des lignes quittées depuis longtemps avant celle qu'on regarde.
func checkPrefetchWindow() {
    func media(_ name: String) -> Item {
        Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false, size: 2_048,
             modified: nil, mimeType: nil)
    }
    func folder(_ name: String) -> Item {
        Item(path: "/NAS/\(name)", name: name, isDirectory: true, size: 0,
             modified: nil, mimeType: "inode/directory")
    }

    var window = PrefetchWindow()

    assert(window.replace(with: (1...24).map { media("a\($0).jpg") }) == PrefetchWindow.drainLimit,
           "la première fenêtre démarre ses deux drains")
    assert(window.pending.count == 24)

    // Le scroll avance : la fenêtre précédente est oubliée, pas mise en attente derrière.
    assert(window.replace(with: (1...24).map { media("b\($0).jpg") }) == 0,
           "les drains tournent déjà, une nouvelle consigne n'en démarre pas d'autres")
    assert(window.pending.count == 24,
           "24 et pas 48 — c'est le remplacement qui borne l'arriéré, obtenu \(window.pending.count)")
    assert(window.pending.first?.name == "b1.jpg",
           "un drain doit repartir sur la nouvelle fenêtre, pas finir l'ancienne")

    // Mille consignes d'affilée, comme un scroll rapide : toujours une seule fenêtre.
    for round in 1...1_000 {
        _ = window.replace(with: (1...24).map { media("c\(round)-\($0).jpg") })
    }
    assert(window.pending.count == 24,
           "mille consignes ne doivent pas laisser mille fenêtres, obtenu \(window.pending.count)")
    assert(window.drains == PrefetchWindow.drainLimit,
           "les drains ne se multiplient pas non plus, obtenu \(window.drains)")

    // Les dossiers n'ont pas de vignette à précharger.
    _ = window.replace(with: [folder("Vacances"), media("x.jpg"), folder("Noël")])
    assert(window.pending.map(\.name) == ["x.jpg"], "seuls les médias entrent dans la fenêtre")

    // Un drain qui vide la fenêtre rend sa place, sinon plus personne ne précharge ensuite.
    assert(window.next()?.name == "x.jpg")
    assert(window.next() == nil)
    assert(window.drains == PrefetchWindow.drainLimit - 1,
           "le drain épuisé a rendu sa place, obtenu \(window.drains)")
    assert(window.next() == nil)
    assert(window.drains == PrefetchWindow.drainLimit - 2)
    assert(window.replace(with: [media("y.jpg")]) == PrefetchWindow.drainLimit,
           "fenêtre sans drain : la consigne suivante doit les relancer tous")

    // Une consigne vide ne démarre rien — il n'y aurait rien à faire, et le drain lancé
    // rendrait aussitôt une place qu'on vient de lui donner.
    var idle = PrefetchWindow()
    assert(idle.replace(with: []) == 0)
    assert(idle.drains == 0, "aucun drain pour une fenêtre vide, obtenu \(idle.drains)")

    print("ok — fenêtre de préchargement : remplacée, bornée, drains rendus")
}
