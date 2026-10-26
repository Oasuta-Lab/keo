import Foundation

/// The iCloud sync rests on three pure pieces: deterministic record names, a change journal
/// written in the same transaction as the change, and a conflict policy biased towards
/// resurrection. If any of these lies, favourites silently vanish or bounce between devices.
func checkSync() async throws {
    // --- nommage déterministe des enregistrements ---------------------------------------
    let fav = SyncIdentity.favourite(path: "/NAS/Photos/a.jpg", size: 2_048)
    assert(fav.recordName == SyncIdentity.favourite(path: "/NAS/Photos/a.jpg", size: 2_048).recordName,
           "deux appareils qui ajoutent le même favori doivent écrire le même enregistrement")
    assert(fav.recordName != SyncIdentity.favourite(path: "/NAS/Photos/a.jpg", size: 2_049).recordName,
           "la taille fait partie de l'identité : un fichier remplacé est un autre favori")
    assert(fav.recordName.hasPrefix("fav-"), "le préfixe dit ce que c'est — \(fav.recordName)")
    assert(SyncIdentity.shortcut(path: "/NAS/Photos/a.jpg").recordName
        != SyncIdentity.collection(name: "/NAS/Photos/a.jpg").recordName,
           "le genre fait partie de l'identité, un même texte ne doit pas entrer en collision")
    assert(SyncIdentity.member(collection: "Vacances", path: "/a.jpg", size: 1).recordName
        != SyncIdentity.member(collection: "Famille", path: "/a.jpg", size: 1).recordName,
           "une même photo dans deux collections fait deux enregistrements")

    // --- sérialisation du contenu --------------------------------------------------------
    let payload = SyncPayload.member(collection: "Vacances", path: "/NAS/Noël/aoé.jpg",
                                     name: "aoé.jpg", size: 7, added: 1_000, modified: 2_000)
    let decoded = SyncPayload.decoded(from: try payload.encoded())
    assert(decoded == payload, "le journal doit restituer exactement ce qu'on y a mis")
    assert(decoded?.identity == .member(collection: "Vacances", path: "/NAS/Noël/aoé.jpg", size: 7),
           "l'identité se redérive du contenu, c'est elle qui nomme l'enregistrement")
    assert(SyncPayload(kind: "member", path: "/a.jpg", name: nil, size: nil, added: nil,
                       collection: nil, created: nil, modified: 0).identity == nil,
           "un enregistrement tronqué ne doit pas être appliqué à moitié")
    assert(SyncPayload.decoded(from: "pas du json") == nil)

    // --- résolution de conflit -----------------------------------------------------------
    assert(SyncConflict.keepLocal(localModified: 2, serverModified: 1),
           "dernier écrivain gagne : la version la plus récente l'emporte")
    assert(!SyncConflict.keepLocal(localModified: 1, serverModified: 2))
    assert(!SyncConflict.keepLocal(localModified: 2, serverModified: 2),
           "à égalité le serveur gagne, pour que tous les appareils convergent sur les mêmes octets")

    // --- le journal de changements, sur le vrai SQLite -----------------------------------
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("keo-sync-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func photo(_ name: String, size: Int64 = 2_048) -> Item {
        Item(path: "/NAS/Photos/\(name)", name: name, isDirectory: false, size: size,
             modified: nil, mimeType: "image/jpeg")
    }

    let store = IndexStore(directory: home)
    let a = photo("a.jpg"), b = photo("b.jpg")

    try await store.setFavourite([a], true)
    var pending = try await store.pendingSyncChanges()
    assert(pending.count == 1 && pending[0].op == .save,
           "ajouter un favori doit laisser une trace à pousser")
    assert(pending[0].recordName == SyncIdentity.favourite(path: a.path, size: a.size).recordName,
           "la trace porte le nom déterministe de l'enregistrement")
    let journalled = pending[0].payload.flatMap(SyncPayload.decoded(from:))
    assert(journalled?.path == a.path && journalled?.size == a.size,
           "la trace contient tout ce qu'il faut pour reconstruire l'enregistrement")

    try await store.setFavourite([a], false)
    pending = try await store.pendingSyncChanges()
    assert(pending.count == 1 && pending[0].op == .delete,
           "ajouter puis retirer se replie en une seule trace, la dernière : \(pending.count)")

    // --- acquittement : rien n'est perdu, rien n'est envoyé deux fois --------------------
    try await store.setFavourite([a], true)
    let sent = try await store.pendingSyncChange(
        recordName: SyncIdentity.favourite(path: a.path, size: a.size).recordName)!
    try await store.clearSyncPendingSave(recordName: sent.recordName, ifUnchangedSince: sent.changed)
    pending = try await store.pendingSyncChanges()
    assert(pending.isEmpty, "un envoi confirmé sort du journal")

    try await store.setFavourite([a], false)                   // re-modifié pendant l'envoi…
    try await store.clearSyncPendingSave(recordName: sent.recordName, ifUnchangedSince: sent.changed)
    pending = try await store.pendingSyncChanges()
    assert(pending.count == 1 && pending[0].op == .delete,
           "un acquittement périmé ne doit pas emporter un changement plus récent")
    try await store.setFavourite([a], true)                    // le délete en vol est re-devenu save
    try await store.clearSyncPendingDelete(recordName: sent.recordName)
    pending = try await store.pendingSyncChanges()
    assert(pending.count == 1 && pending[0].op == .save,
           "l'acquittement d'une suppression ne touche pas la ré-addition survenue entre-temps")
    try await store.clearSyncPendingSave(recordName: sent.recordName, ifUnchangedSince: .infinity)

    // --- application distante : jamais de boucle -----------------------------------------
    let remote = SyncPayload.favourite(path: b.path, name: b.name, size: b.size,
                                       added: 1_000, modified: 1_000)
    try await store.applyRemote(saves: [remote], deletes: [])
    var favs = try await store.favourites()
    assert(favs.map(\.name).contains("b.jpg"), "un favori venu d'un autre appareil apparaît")
    pending = try await store.pendingSyncChanges()
    assert(pending.isEmpty,
           "appliquer un changement distant ne doit PAS le re-journaliser : sinon deux appareils "
         + "se renvoient le même changement pour toujours")

    let bName = SyncIdentity.favourite(path: b.path, size: b.size).recordName
    try await store.applyRemote(saves: [], deletes: [bName])
    favs = try await store.favourites()
    assert(!favs.map(\.name).contains("b.jpg"), "une suppression distante se propage")
    pending = try await store.pendingSyncChanges()
    assert(pending.isEmpty, "et ne laisse aucune trace à renvoyer — pas de boucle de suppression")

    // --- le biais de résurrection --------------------------------------------------------
    try await store.setFavourite([a], true)                    // save local pas encore poussé
    let aName = SyncIdentity.favourite(path: a.path, size: a.size).recordName
    try await store.applyRemote(saves: [], deletes: [aName])
    favs = try await store.favourites()
    assert(favs.map(\.name).contains("a.jpg"),
           "une suppression distante ne gagne pas contre un ajout local pas encore poussé : "
         + "dans le doute, le favori ressuscite")

    try await store.setFavourite([a], false)                   // délete local pas encore poussé
    try await store.applyRemote(saves: [SyncPayload.favourite(
        path: a.path, name: a.name, size: a.size, added: 1, modified: 1)], deletes: [])
    pending = try await store.pendingSyncChanges()
    assert(!pending.contains { $0.recordName == aName && $0.op == .delete },
           "un save distant annule le délete local en attente — même biais, même raison")
    favs = try await store.favourites()
    assert(favs.map(\.name).contains("a.jpg"))
    try await store.setFavourite([a], false)
    _ = try await store.pendingSyncChanges().isEmpty          // tombstone restant, peu importe

    // --- collections : le renommage change l'identité ------------------------------------
    func drain() async throws {
        for change in try await store.pendingSyncChanges() {
            if change.op == .save {
                try await store.clearSyncPendingSave(recordName: change.recordName,
                                                     ifUnchangedSince: change.changed)
            } else {
                try await store.clearSyncPendingDelete(recordName: change.recordName)
            }
        }
    }
    try await drain()

    let trips = try await store.createCollection(named: "Voyages")
    try await store.setMembership([a], in: trips, true)
    try await drain()

    try await store.renameCollection(trips, to: "Vacances")
    pending = try await store.pendingSyncChanges()
    let oldCol = SyncIdentity.collection(name: "Voyages").recordName
    let newCol = SyncIdentity.collection(name: "Vacances").recordName
    let oldMem = SyncIdentity.member(collection: "Voyages", path: a.path, size: a.size).recordName
    let newMem = SyncIdentity.member(collection: "Vacances", path: a.path, size: a.size).recordName
    assert(pending.contains { $0.recordName == oldCol && $0.op == .delete }
        && pending.contains { $0.recordName == newCol && $0.op == .save }
        && pending.contains { $0.recordName == oldMem && $0.op == .delete }
        && pending.contains { $0.recordName == newMem && $0.op == .save },
           "renommer = supprimer l'ancienne identité et créer la nouvelle, membres compris : "
         + "deux appareils qui créent « Vacances » chacun de leur côté n'en font qu'une")
    try await drain()

    try await store.deleteCollection(trips)
    pending = try await store.pendingSyncChanges()
    assert(pending.contains { $0.recordName == newMem && $0.op == .delete },
           "supprimer une collection journalise aussi la suppression de ses membres : "
         + "sinon ils ressusciteraient la collection sur les autres appareils")
    try await drain()

    // Suppression contre ajout de membre, hors ligne : l'ajout gagne et recrée la collection.
    let orphan = SyncPayload.member(collection: "Vacances", path: b.path, name: b.name,
                                    size: b.size, added: 3_000, modified: 3_000)
    try await store.applyRemote(saves: [orphan], deletes: [])
    let resurrected = try await store.collections()
    assert(resurrected.map(\.name) == ["Vacances"],
           "un membre reçu pour une collection disparue la recrée — résurrection assumée")
    assert(resurrected[0].count == 1)

    // --- premier lancement avec des données préexistantes --------------------------------
    try await store.applyRemote(saves: [], deletes: [newCol,
        SyncIdentity.member(collection: "Vacances", path: b.path, size: b.size).recordName])
    try await store.setFavourite([a, b], true)
    try await store.setShortcut(Item(path: "/NAS/Photos", name: "Photos", isDirectory: true,
                                     size: 0, modified: nil, mimeType: nil), true)
    try await drain()

    let seeded = try await store.seedSyncJournalIfNeeded()
    assert(seeded, "la première activation doit semer le journal avec l'existant")
    pending = try await store.pendingSyncChanges()
    assert(pending.count == 3 && pending.allSatisfy { $0.op == .save },
           "tout l'existant remonte, une trace par enregistrement — \(pending.count)")
    let reseeded = try await store.seedSyncJournalIfNeeded()
    assert(!reseeded, "la graine ne se sème qu'une fois, sinon chaque lancement re-pousserait tout")

    // --- zone supprimée : tout re-remonte, sans ressusciter les tombes -------------------
    try await drain()
    try await store.setFavourite([b], false)                   // une tombe en attente
    try await store.journalAllPersonalisation()
    pending = try await store.pendingSyncChanges()
    assert(pending.contains { $0.recordName == bName && $0.op == .delete },
           "re-journaliser l'existant ne doit pas transformer une suppression en ajout")
    assert(pending.contains { $0.recordName == aName && $0.op == .save })

    // --- changement de compte : on ne mélange jamais deux personnes ----------------------
    try await store.setSyncAccountID("_user-A")
    let who = try await store.syncAccountID()
    assert(who == "_user-A")
    var emptiness = try await store.personalisationIsEmpty()
    assert(!emptiness)
    try await store.wipePersonalisation()
    emptiness = try await store.personalisationIsEmpty()
    assert(emptiness, "au changement de compte, la personnalisation de l'ancien compte s'efface")
    pending = try await store.pendingSyncChanges()
    assert(pending.isEmpty, "et son journal avec : rien de l'ancien compte ne doit partir vers le nouveau")
    let fetched = try await store.syncFetchedOnce()
    assert(!fetched, "après bascule, « vide » veut dire « pas encore récupéré », pas « rien »")
    let count = try await store.fileCount()
    _ = count   // l'index, lui, n'est pas personnel : il ne bouge pas
    try await store.setSyncFetchedOnce()
    let nowFetched = try await store.syncFetchedOnce()
    assert(nowFetched, "une première récupération terminée lève l'état « récupération en cours »")

    print("ok — sync : noms déterministes, journal, acquittements, résurrection, renommage, "
        + "graine, zone, changement de compte")

    checkFetchedChangesAreNeverDroppedSilently()
    checkTheTokenSurvivesAFailedRewrite()
}

/// Source scan, same spirit as `checkTheAppTokenCanSync` in main.swift: once the event handler
/// returns, the engine counts fetched records as consumed — records the store refused to write
/// exist nowhere else, so swallowing that error with `try?` loses favourites and notes coming
/// from another device until a full refetch.
func checkFetchedChangesAreNeverDroppedSilently() {
    let file = URL(fileURLWithPath: "Keo/Sync/CloudSync.swift")
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
        assertionFailure("CloudSync.swift introuvable — lance le check depuis la racine du dépôt")
        return
    }
    let source = strippingComments(raw)
    assert(!source.contains("try? await store.applyRemote"),
           "un échec d'écriture des changements reçus doit se traiter, pas se taire : "
         + "le moteur les croit consommés et ils seraient perdus jusqu'au prochain refetch")
    assert(source.contains("holdStatePersistence"),
           "sans gel de l'état du moteur, l'acquittement d'un changement jamais stocké atteint le disque")
}

/// The promise in Keychain.swift — « an add that fails must cost nothing » — broke once by
/// deleting the synchronizable token *before* rewriting it. Scanned at the source because the
/// failure is silent: no error, no log, just a household asked to press ✓ on the box again.
func checkTheTokenSurvivesAFailedRewrite() {
    let file = URL(fileURLWithPath: "Keo/App/Keychain.swift")
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
        assertionFailure("Keychain.swift introuvable — lance le check depuis la racine du dépôt")
        return
    }
    let source = strippingComments(raw)
    guard let set = source.range(of: "static func set"),
          let get = source.range(of: "static func get") else {
        assertionFailure("Keychain.swift ne ressemble plus à ce que ce scan sait lire")
        return
    }
    let body = source[set.upperBound..<get.lowerBound]
    assert(body.contains("SecItemUpdate"),
           "écrire le jeton passe par une mise à jour en place : supprimer avant d'ajouter "
         + "perd le jeton du foyer si l'ajout échoue")
    guard let add = body.range(of: "SecItemAdd"), let delete = body.range(of: "SecItemDelete") else {
        assertionFailure("set() ne contient plus les appels que ce scan sait ordonner")
        return
    }
    assert(add.lowerBound < delete.lowerBound,
           "rien ne se supprime avant que la nouvelle écriture ait réussi")
}
