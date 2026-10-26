# Keo — à respecter

README.md explique **pourquoi** le code est comme ça. Ce fichier dit **ce qui s'applique**.
En cas de doute sur une intention de conception, lire la section correspondante du README.

## 1. Règle non négociable

**Keo ne touche jamais aux données du NAS.** Pas de déplacement, pas de modification, pas de
suppression, pas de création. Jamais, sous aucun prétexte, même demandé en passant.

C'est structurel, pas déclaratif :

- `ReadOnlyTransport` (`Keo/Freebox/Transport.swift`) est la seule porte vers le NAS et
  n'expose ni méthode HTTP ni corps de requête. Écrire demanderait d'ajouter une méthode à ce
  type — ne pas le faire.
- Le seul `httpMethod = "POST"` de l'app est la poignée de main de login, dans
  `LoginTransport`.
- `checkNothingWritesToTheNAS()` dans `Tests/main.swift` relit les sources et échoue si un
  `PUT`/`DELETE`/`PATCH`/`MOVE` ou une route `fs/mv`, `fs/rm`, `fs/mkdir`… apparaît ailleurs
  que dans un commentaire.

Ne jamais affaiblir, contourner ni « temporairement » désactiver l'un des trois.

## 2. Avant de dire que c'est fait

Lancer la vérification. Elle doit être verte, et c'est **la** commande — si un fichier est
ajouté à la liste, le faire ici et nulle part ailleurs.

```sh
rm -f /tmp/keocheck   # sinon un échec de compilation relance l'ancien binaire et ment
swiftc -swift-version 6 -D DEBUG \
  Keo/Freebox/Item.swift Keo/Freebox/MediaSection.swift Keo/Freebox/Transport.swift \
  Keo/Freebox/FreeboxClient.swift Keo/Downloads/DownloadJob.swift \
  Keo/Media/DiskCache.swift Keo/Media/PreviewPolicy.swift Keo/Media/FolderStamp.swift \
  Keo/Media/WalkOutcome.swift Keo/Media/SearchQuery.swift Keo/Media/Statistics.swift \
  Keo/Media/LivePhotos.swift Keo/Media/FolderExclusion.swift Keo/Media/FilenameDate.swift \
  Keo/Media/IndexStore.swift Keo/Media/PrefetchWindow.swift \
  Keo/Media/VideoDate.swift Keo/Media/WidgetManifest.swift Keo/Sync/SyncModel.swift \
  Keo/UI/MediaDate.swift Keo/UI/RailLayout.swift Keo/UI/BrowserSource.swift \
  Keo/UI/DeepLink.swift Keo/UI/HumanDate.swift \
  Tests/main.swift Tests/store.swift Tests/favourites.swift Tests/videodatechecks.swift \
  Tests/sync.swift Tests/search.swift Tests/covers.swift Tests/notes.swift \
  Tests/stats.swift Tests/widget.swift Tests/links.swift Tests/live.swift Tests/dates.swift \
  Tests/exclusions.swift Tests/prefetch.swift Tests/previews.swift \
  -o /tmp/keocheck && /tmp/keocheck
```

Puis compiler pour l'appareil — la vérification ci-dessus ne compile aucun fichier SwiftUI :

```sh
xcodebuild -project Keo.xcodeproj -scheme Keo -configuration Debug \
  -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|\*\* BUILD"
```

Un fichier de `Tests/` ne doit pas porter le nom d'un fichier de `Keo/` à la casse près :
le système de fichiers est insensible à la casse, les deux produisent le même fichier objet,
et l'édition de liens échoue sur des symboles introuvables sans jamais nommer la cause.
`DeepLink.swift` et `HumanDate.swift` ont chacun coûté cette erreur.

Toute logique non triviale ajoutée laisse une vérification derrière elle, dans `Tests/`, en
français, sur le vrai SQLite quand c'est du stockage. Pas de framework, pas de fixtures.

## 3. Conventions

- Swift 6 en concurrence stricte, cible iOS 18, **aucune dépendance externe** — frameworks
  système uniquement. Ne pas en ajouter.
- Commentaires en **anglais**. Chaînes affichées à l'utilisateur et vérifications en
  **français**.
- Un commentaire explique **pourquoi**, jamais quoi. Un commentaire qui paraphrase la ligne
  en dessous est à supprimer.
- Pas d'abstraction spéculative : pas de protocole à une implémentation, pas de réglage pour
  une valeur qui ne change jamais.
- Les dépendances vont vers l'intérieur : `UI` → `Media`/`Downloads` → `Freebox`. Rien dans
  `Freebox` ne connaît SwiftUI.
- La logique qu'on veut pouvoir vérifier vit hors SwiftUI (`RailLayout`, `WalkOutcome`,
  `SearchQuery`, `BrowserSource.parent(of:)`). Continuer comme ça.

## 4. Appareil

Le projet a **deux cibles** depuis le widget. Construire avec
`-allowProvisioningUpdates` : le groupe d'app doit être enregistré contre l'App ID, et sans
ce drapeau la signature échoue pour l'app *et* pour l'extension.

```sh
xcodebuild -project Keo.xcodeproj -scheme Keo -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
ls ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app/PlugIns/
```

La seconde ligne n'est pas décorative : une édition du `project.pbxproj` qui perd la phase
d'embarquement produit une app qui compile et s'installe **sans son extension**, sans erreur.

```sh
xcrun devicectl list devices                     # UDID des appareils branchés
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app
xcrun devicectl device process launch --device <UDID> --console com.oasutalab.keo \
  2>&1 | grep -a --line-buffered "\[keo\]"
```

Les traces `[keo]` sont aussi écrites dans le conteneur de l'app, parce que la session
`--console` meurt dès que l'app est relancée depuis l'écran d'accueil. Les récupérer :

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.oasutalab.keo \
  --source "Library/Application Support/Keo/trace.log" --destination /tmp/
```

Le même mécanisme sort `index.sqlite` quand il faut savoir ce que l'appareil a vraiment en
base plutôt que le demander.

- Le `CFBundleVersion` est le nombre de commits, tamponné au build. Ne pas le saisir à la main.
- **Ne jamais réinstaller pendant qu'une mesure ou un test tourne sur l'appareil** :
  l'installation tue le processus et la session console avec. Ça a déjà fait perdre une mesure.
- Si `codesign` rend `errSecInternalComponent`, le trousseau de session est verrouillé : c'est
  au propriétaire de le déverrouiller depuis Terminal.app, pas quelque chose à contourner.

## 5. Pièges qui ont déjà coûté cher

- **Les rapports de plantage sont sur l'appareil**, et ils donnent la réponse en une minute
  là où le raisonnement donne une hypothèse :
  ```sh
  xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs | grep -i keo
  xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs \
    --source "Keo-….ips" --destination /tmp/
  ```
  Le fichier `.ips` est deux objets JSON collés : métadonnées sur la première ligne, rapport
  sur le reste.
- **Cycle de vie de l'indexation** : trois correctifs plausibles et faux avant celui qui a
  marché. Ne rien y changer sur la foi d'un raisonnement — brancher la console de l'appareil
  d'abord et partir de ce qu'elle raconte. Voir README, « Lire les traces de l'appareil ».
- **`Pairing.appID` est ce que la box a autorisé**, pas l'identifiant de bundle — ils
  coïncident aujourd'hui, c'est tout. Le changer invalide l'autorisation : jeton refusé,
  `Store.reconnectIfPossible` le jette, et il faut réappuyer sur ✓ sur la face avant de la
  Freebox. Ne pas y toucher sans le dire.
- **`navigationDestination` dans une vue qui se pousse elle-même.** `BrowserView` est
  récursive : chaque instance redéclarait la destination des mêmes types, donc une pile de
  trois niveaux en avait trois concurrentes. SwiftUI ne promet rien dans ce cas et reconstruit
  la destination — l'état de la vue est détruit, la grille se recharge toutes les quelques
  secondes et la position de lecture est perdue. Les destinations se déclarent **une fois, à
  la racine de la pile** (`PushTargets`), les vues poussées en héritent. **La variante
  `navigationDestination(item:)` compte aussi** : le piège a été refermé pour `for:` et laissé
  ouvert pour `item:`, et il est revenu intact — le fil d'Ariane bouclait. Une vue récursive ne
  déclare aucune destination ; pour pousser ou dépiler elle lit `\.stackPath`, le chemin que la
  pile publie dans l'environnement.
- **La date de modification n'est pas une date de prise de vue.** Sur un NAS c'est la date de
  copie. Ne jamais la laisser alimenter le tri, les sections ou la timeline — elle y fait
  remonter en tête des photos que personne n'a prises ce jour-là. Elle se dit sous la photo,
  et nulle part ailleurs.
- **Migration de schéma SQLite** : une colonne `NOT NULL DEFAULT 0` sur `kind` a transformé
  toutes les photos déjà indexées en dossiers. Vérifier ce que vaut la valeur par défaut dans
  l'énumération, pas seulement dans le SQL.
- **Mesurer, pas supposer** : un banc d'essai qui rejoue les mêmes fichiers mesure le cache.
  Un seul échantillon ne remplace pas une supposition, il la déguise.
- **Ne pas prétendre avoir testé ce qui demande l'appareil ou le vrai iCloud.** Écrire le plan
  de test manuel dans le README à la place.
