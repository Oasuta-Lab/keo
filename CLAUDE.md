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
  Keo/Media/WalkOutcome.swift Keo/Media/SearchQuery.swift Keo/Media/IndexStore.swift \
  Keo/Media/VideoDate.swift Keo/Sync/SyncModel.swift \
  Keo/UI/MediaDate.swift Keo/UI/RailLayout.swift Keo/UI/BrowserSource.swift \
  Tests/main.swift Tests/store.swift Tests/favourites.swift Tests/videodatechecks.swift \
  Tests/sync.swift Tests/search.swift Tests/covers.swift \
  -o /tmp/keocheck && /tmp/keocheck
```

Puis compiler pour l'appareil — la vérification ci-dessus ne compile aucun fichier SwiftUI :

```sh
xcodebuild -project Keo.xcodeproj -scheme Keo -configuration Debug \
  -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|\*\* BUILD"
```

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

```sh
xcrun devicectl list devices                     # UDID des appareils branchés
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app
xcrun devicectl device process launch --device <UDID> --console com.oasutalab.keo \
  2>&1 | grep -a --line-buffered "\[keo\]"
```

- Le `CFBundleVersion` est le nombre de commits, tamponné au build. Ne pas le saisir à la main.
- **Ne jamais réinstaller pendant qu'une mesure ou un test tourne sur l'appareil** :
  l'installation tue le processus et la session console avec. Ça a déjà fait perdre une mesure.
- Si `codesign` rend `errSecInternalComponent`, le trousseau de session est verrouillé : c'est
  au propriétaire de le déverrouiller depuis Terminal.app, pas quelque chose à contourner.

## 5. Pièges qui ont déjà coûté cher

- **Cycle de vie de l'indexation** : trois correctifs plausibles et faux avant celui qui a
  marché. Ne rien y changer sur la foi d'un raisonnement — brancher la console de l'appareil
  d'abord et partir de ce qu'elle raconte. Voir README, « Lire les traces de l'appareil ».
- **`Pairing.appID` est ce que la box a autorisé**, pas l'identifiant de bundle — ils
  coïncident aujourd'hui, c'est tout. Le changer invalide l'autorisation : jeton refusé,
  `Store.reconnectIfPossible` le jette, et il faut réappuyer sur ✓ sur la face avant de la
  Freebox. Ne pas y toucher sans le dire.
- **Migration de schéma SQLite** : une colonne `NOT NULL DEFAULT 0` sur `kind` a transformé
  toutes les photos déjà indexées en dossiers. Vérifier ce que vaut la valeur par défaut dans
  l'énumération, pas seulement dans le SQL.
- **Mesurer, pas supposer** : un banc d'essai qui rejoue les mêmes fichiers mesure le cache.
  Un seul échantillon ne remplace pas une supposition, il la déguise.
- **Ne pas prétendre avoir testé ce qui demande l'appareil ou le vrai iCloud.** Écrire le plan
  de test manuel dans le README à la place.
