# Keo

Galerie photos/vidéos iOS native pour Freebox, via l'API Freebox OS.
SwiftUI, Swift 6 en concurrence stricte, aucune dépendance externe.

## Règle non négociable

**Keo ne modifie jamais rien sur le NAS.** Pas de déplacement, pas de renommage, pas de
suppression, pas d'écriture. Ce n'est pas une intention, c'est une contrainte structurelle :

- `ReadOnlyTransport` est la seule porte vers le NAS et n'expose que des lectures. Aucun
  paramètre de méthode HTTP, aucun corps de requête. Écrire demanderait d'ajouter une méthode
  à ce type.
- La poignée de main de login, seul endroit qui fait un `POST`, vit dans `LoginTransport`,
  hors de portée du chemin de données.
- `Tests/main.swift` relit les sources et échoue si un `PUT`/`DELETE`/`MOVE` ou une route
  `fs/mv`, `fs/rm`, `fs/mkdir`… apparaît ailleurs que dans un commentaire.

## Lancer

```sh
open Keo.xcodeproj     # ⌘R
```

Au premier lancement : « Associer à la Freebox », puis **appuyer sur ✓ sur la face avant du
Freebox Server**. Le jeton d'application va dans le trousseau iOS.

Si la navigation renvoie une erreur de droits : Freebox OS → Paramètres → Gestion des accès →
Applications → Keo → cocher « Accès aux fichiers ».

## Numéro de build

`Scripts/stamp-build.sh` tamponne l'`Info.plist` **construit** — jamais celui du dépôt — au
cours d'une phase de build :

- `CFBundleVersion` = nombre de commits, donc il monte à chaque commit, sans saisie manuelle
- `KeoCommit` = hash court, suffixé d'un `+` si la build portait des modifications non commitées

Affiché en petit en bas de l'écran d'association et de la racine de la galerie, sous la forme
`v0.1 (13) · a1b2c3d`. Il disparaît dès qu'une barre de sélection ou de téléchargement occupe
le bas de l'écran, et n'apparaît pas dans les sous-dossiers ni en plein écran.

Sans git (build depuis une archive), le script sort sans rien faire et la valeur du dépôt est
conservée.

## Structure

| Dossier | Rôle |
|---|---|
| `Keo/App/` | Entrée, `Store` (session, association), trousseau, tampon de build |
| `Keo/Freebox/` | `Item` et `FolderContents`, transports, client, asset vidéo authentifié |
| `Keo/Media/` | Pipeline de vignettes, décodage ImageIO, cache disque évincé en LRU |
| `Keo/Downloads/` | File d'attente, pellicule, feuille de partage |
| `Keo/UI/` | Association, grille, visionneuse plein écran |

Les dépendances vont vers l'intérieur : `UI` → `Media`/`Downloads` → `Freebox`. Rien dans
`Freebox` ne connaît SwiftUI.

Le découpage en paquets SPM a été volontairement différé : à cette taille il ajouterait de la
cérémonie sans réduire la complexité. Les frontières sont déjà posées pour le faire le jour où
plusieurs personnes travaillent dessus en parallèle.

## Date affichée en plein écran

Le nom et la date apparaissent en haut, dans une capsule translucide.

La date vient de l'**EXIF** (`DateTimeOriginal`) quand le fichier la porte — lisible
gratuitement, puisque la visionneuse télécharge déjà l'original. Pour les vidéos, c'est
`creationDate` de l'asset. À défaut, la date de modification est affichée **préfixée de
« Modifié le »** : une date de copie ne doit jamais passer pour une date de prise de vue.
Sans aucune date, rien ne s'affiche plutôt qu'une date inventée.

C'est aussi la réponse à la limite du tri : en plein écran, la vraie date est connue. La
grille, elle, ne peut pas trier là-dessus sans télécharger un bout de chaque fichier.

## Tri

Menu « … » → trois ordres, mémorisés pour toute l'app : plus récentes d'abord (défaut),
plus anciennes d'abord, par nom. Changer d'ordre ne redemande rien à la box, le tri est local.

Deux choix à connaître :

- **La date est celle de modification du fichier**, pas la date de prise de vue. L'API ne
  renvoie que `modification`. Lire la date EXIF demanderait de télécharger un bout de chaque
  fichier avant de pouvoir trier, ce qui est intenable sur un grand dossier.
- **Les dossiers restent alphabétiques.** Le mtime d'un dossier dit quand on a écrit dedans
  pour la dernière fois, ce qui n'est presque jamais ce qu'on entend par « la date de ces photos ».

Les fichiers sans date vont à la fin, pas au 1ᵉʳ janvier 1970.

## Tenue à l'échelle

La galerie est supposée très grande. Ce qui a été fait pour ça :

| Point | Choix |
|---|---|
| Mémoire des vignettes | Budget en **octets** (80 Mo), pas en nombre d'images |
| Qualité des aperçus | Un aperçu embarqué est refusé s'il fait moins de 75 % de la taille demandée, ou si son ratio ne correspond pas à la photo |
| Concurrence | Deux portes : 4 fetchs visibles, 2 préchargements — un prefetch ne bloque jamais une cellule à l'écran |
| Doublons | Une tâche par clé, partagée par tous les appelants |
| Préchargement | Fenêtre de 24 éléments en avance sur le défilement |
| Cache disque | 512 Mo, éviction LRU au lancement |
| Grandes images | Téléchargées sur disque puis décodées depuis le fichier — jamais de `Data` plein format en mémoire |
| Découpage du dossier | `FolderContents` calculé une fois au chargement, pas à chaque rendu |
| Visionneuse | `ScrollView` paginé + `LazyHStack`, pas un `TabView` qui garde l'identité de tous les éléments |

Les idées viennent de [Nuke](https://github.com/kean/Nuke) ; le fetch est maison parce qu'une
vignette Keo est une requête Range de 256 Ko plus un décodage d'aperçu embarqué, pas un
téléchargement d'URL.

## Qualité des vignettes

Trois défauts constatés sur de vrais fichiers, et ce qui les corrige :

- **Aperçu embarqué minuscule.** Un JPEG 6016×6016 peut n'embarquer qu'une vignette EXIF de
  160×160 : étirée dans une cellule de 400 px, elle est floue. `PreviewPolicy` la refuse en
  dessous de 75 % de la taille demandée et bascule sur le décodage du fichier complet, mis en
  cache ensuite — le coût est payé une fois.
- **Mauvais cadrage.** Certains aperçus ont un ratio différent de la photo (vignette 4:3 pour
  une image 16:9), donc recadrent ou ajoutent des bandes. Au-delà de 2 % d'écart de ratio, on
  refuse. L'orientation EXIF est prise en compte : les quarts de tour échangent largeur et hauteur.
- **Vignettes blanches.** Le cache disque encodait en JPEG, qui n'a pas de canal alpha : un PNG
  transparent en revenait en **blanc pur** (vérifié : `r=255 g=255 b=255`). Les images avec
  transparence sont désormais stockées en PNG.

Contrepartie assumée : un fichier dont l'aperçu est refusé coûte un téléchargement complet au
premier affichage. Si la première descente dans un gros dossier devient trop lente, la suite
est l'affichage progressif — petit aperçu tout de suite, remplacé par la bonne vignette.

## Vérifier

```sh
rm -f /tmp/keocheck   # sinon un echec de compilation relance l'ancien binaire
swiftc -swift-version 6 Keo/Freebox/Item.swift Keo/Freebox/Transport.swift \
  Keo/Freebox/FreeboxClient.swift Keo/Downloads/DownloadJob.swift \
  Keo/Media/DiskCache.swift Keo/Media/PreviewPolicy.swift \
  Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
```

Couvre la garantie de lecture seule, l'enveloppe `{success, result}`, l'encodage des chemins,
la classification des médias, l'éviction LRU et l'arithmétique de progression.

## Pièges de l'API Freebox, vérifiés sur la box

- `fs/ls` renvoie `result = {"entries": [...]}`, **pas** un tableau nu.
- Les chemins sont du base64 percent-encodé. `URL.appendingPathComponent` ré-encode le `%`
  (`Lw%3D%3D` → `Lw%253D%253D`) et la box répond `invalid_request` : construire l'URL avec
  `URL(string:relativeTo:)`.
- `dl/` honore `Range` (206 Partial Content) : 256 Ko d'un JPEG de 2 Mo suffisent à extraire
  un aperçu embarqué de 400 px.
- `fs/thumbnail` **n'existe pas**, la box ne génère aucune vignette.
- `AVURLAssetHTTPHeaderFieldsKey` n'est pas documenté et iOS l'ignore : AVFoundation doit
  passer par un `AVAssetResourceLoaderDelegate` pour porter `X-Fbx-App-Auth`.
- `mafreebox.freebox.fr` résout vers une IP publique : ATS a besoin d'une exception de
  domaine, `NSAllowsLocalNetworking` ne suffit pas.

## Limites connues

- **LAN uniquement.** L'accès distant existe côté box mais son certificat vient de la CA
  Freebox, absente du magasin iOS. Un VPN IKEv2 sur la Freebox est la meilleure réponse : le
  téléphone se retrouve sur le réseau local et l'app n'a pas une ligne à changer.
- **Pas de téléchargement de dossier entier** — la sélection porte sur des fichiers.
- **Téléchargements en série** — une barre de progression lisible plutôt qu'un débit maximal.
- **Pas de cible de tests Xcode.** La logique vérifiable est pure et le script ci-dessus suffit ;
  à ajouter le jour où il faudra tester du code qui a besoin du simulateur.
