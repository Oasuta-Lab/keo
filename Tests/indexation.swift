import Foundation

/// La ligne de l'accueil : un ordre de priorité, pas une formule.
///
/// Ce qui est vérifié ici est l'**ordre**. Chaque branche prise isolément est triviale ; ce qui
/// ne l'est pas, c'est que l'échec passe avant le retard, que le retard passe avant la
/// fraîcheur, et qu'une marche en cours ne soit jamais recouverte par l'un des deux.
func checkIndexingLine() {
    let hier = Date(timeIntervalSinceNow: -86_400)

    // Rien ne recouvre une marche en cours, pas même des dossiers inaccessibles : ce qui se
    // passe maintenant a toujours la priorité sur le bilan de la fois d'avant.
    let marche = IndexingLine.detail(IndexingLine.Facts(
        running: true, datesRead: 412, unreachable: 3, unread: 900, lastRun: hier))
    assert(marche.text == "En cours · 412 dates lues", "obtenu « \(marche.text) »")
    assert(!marche.warning, "une marche qui avance n'est pas un avertissement")

    // Au tout début d'un passage, aucune date n'est encore lue : mieux vaut les points de
    // suspension qu'un « 0 date lue », le zéro ne se dit jamais.
    let depart = IndexingLine.detail(IndexingLine.Facts(running: true))
    assert(depart.text == "En cours…", "obtenu « \(depart.text) »")

    // Interrompue est le seul état où la personne a un geste à faire : il passe devant tout
    // le reste, et il porte l'ambre.
    let pause = IndexingLine.detail(IndexingLine.Facts(
        paused: true, unreachable: 2, unread: 340, lastRun: hier))
    assert(pause.text == "Interrompue · reste 340", "obtenu « \(pause.text) »")
    assert(pause.warning, "une marche interrompue attend un geste, elle doit se voir")

    // Un index vide ne parle ni de fraîcheur ni de retard : il n'a jamais rien vu.
    let vide = IndexingLine.detail(IndexingLine.Facts(empty: true, unread: 12, lastRun: hier))
    assert(vide.text == "Pas encore commencée", "obtenu « \(vide.text) »")
    assert(!vide.warning, "n'avoir jamais commencé n'est pas une panne")

    // L'échec devant le retard : un partage démonté est ce que personne ne verrait jamais,
    // alors qu'un retard de lecture se résorbe tout seul au passage suivant.
    let panne = IndexingLine.detail(IndexingLine.Facts(
        unreachable: 1, unread: 4_000, lastRun: hier))
    assert(panne.text == "1 dossier inaccessible", "obtenu « \(panne.text) » (singulier français)")
    assert(panne.warning)
    let pannes = IndexingLine.detail(IndexingLine.Facts(unreachable: 3, lastRun: hier))
    assert(pannes.text == "3 dossiers inaccessibles", "obtenu « \(pannes.text) »")

    // Le retard devant la fraîcheur, et sans ambre : la découverte périodique en fabrique
    // toute seule à chaque arrivée de photos, et colorer le cours normal des choses apprend
    // à ignorer la couleur.
    let retard = IndexingLine.detail(IndexingLine.Facts(unread: 340, lastRun: hier))
    assert(retard.text == "340 fichiers à lire", "obtenu « \(retard.text) »")
    assert(!retard.warning, "un retard de lecture est le cours normal des choses")

    // Et quand il ne reste que la réassurance, c'est la fraîcheur qui la porte — jamais un
    // total, et jamais un rapport de dossiers : « X dossiers sur Y » est exactement ce que
    // cet écran a cessé de dire.
    let frais = IndexingLine.detail(IndexingLine.Facts(lastRun: hier))
    assert(frais.text.hasPrefix("Vérifié "), "obtenu « \(frais.text) »")
    assert(!frais.text.contains(" sur "), "obtenu « \(frais.text) »")
    assert(!frais.warning)

    // Aucun passage jamais terminé sur un index non vide : on ne prétend pas à une date.
    let sansDate = IndexingLine.detail(IndexingLine.Facts())
    assert(sansDate.text == "À jour", "obtenu « \(sansDate.text) »")

    print("ok — ligne d'indexation : l'échec devant le retard, le retard devant la fraîcheur, "
        + "et plus un seul rapport de dossiers")
}

/// Le bilan du dernier passage : il survit au relancement, et il part avec l'index qu'il décrit.
func checkLastPass() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-lastpass-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let pass = LastPass(
        finishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        summary: WalkSummary(arrived: 3, foldersVisited: 12, foldersSkipped: 8_300,
                             datesRead: 41, dateless: 2, adopted: 7, unreadable: 1,
                             indexedOverall: 40_861),
        unreachable: 2,
        excluded: 118,
        problems: [IndexProblem(path: "/Disque dur/Photos/2019", reason: "injoignable",
                                trouble: .folderUnreachable),
                   IndexProblem(path: "/Disque dur/Dev/node_modules", reason: "dossier technique",
                                trouble: .folderExcluded)])

    // L'aller-retour par le texte : c'est sous cette forme que le bilan traverse un
    // relancement, et une date encodée autrement est un bilan qui cesse silencieusement
    // de se relire.
    let json = pass.encoded()
    assert(json != nil, "un bilan doit savoir s'écrire")
    assert(LastPass.decode(json!) == pass, "l'aller-retour doit rendre exactement le bilan")

    // Un enregistrement illisible — écrit par une version plus ancienne, par exemple — est
    // une phrase manquante, jamais une panne.
    assert(LastPass.decode("{\"pas\":\"un bilan\"}") == nil)

    let store = IndexStore(directory: home)
    let vierge = await store.lastPass()
    assert(vierge == nil, "un index neuf n'a pas de passage derrière lui")
    await store.rememberLastPass(pass)
    let relu = await store.lastPass()
    assert(relu == pass, "le bilan doit revenir tel quel de SQLite")
    assert(relu?.problems(.folderExcluded).count == 1,
           "le détail par motif est ce qui ouvre la liste des chemins")
    assert(relu?.hasTrouble == true, "deux dossiers injoignables, il y a de quoi regarder")

    // « Tout relire depuis zéro » efface l'index : laisser le bilan derrière ferait annoncer
    // « rien de neuf » au-dessus d'un index qu'on vient de vider.
    try await store.forgetEverything()
    let efface = await store.lastPass()
    assert(efface == nil, "le bilan décrit un index qui n'existe plus")

    print("ok — bilan du dernier passage : il survit au relancement et meurt avec son index")
}
