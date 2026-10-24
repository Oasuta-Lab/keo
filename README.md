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

## Identité

Mascotte et logos viennent de `../keo assets`. Seul ce qui est utilisé est copié dans
`Keo/Assets.xcassets` :

- **`AppIcon`** ← `keo-icon.png`, la version à fond plein. Une icône iOS ne peut pas avoir de
  canal alpha, donc la variante détourée ne convient pas ici.
- **`Mascot`** ← `keo-icon-transparent.png`, détourée (78 % de pixels transparents), affichée
  sur l'écran d'association où le fond est noir.
- **`AccentColor`** ← `#015EB4`, le bleu de marque, éclairci en `#258BE8` en mode sombre où le
  bleu foncé manquerait de contraste. Il teinte toute l'app : boutons, dossiers, rail de la
  timeline.

## Structure

| Dossier | Rôle |
|---|---|
| `Keo/App/` | Entrée, `Store` (session, association), trousseau, tampon de build |
| `Keo/Freebox/` | `Item` et `FolderContents`, transports, client, asset vidéo authentifié |
| `Keo/Media/` | Pipeline de vignettes, décodage ImageIO, cache disque LRU, index des dates |
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

## Dates réelles plutôt que dates de copie

Sur un NAS, la date de modification est souvent le jour où tout a été copié : tous les
fichiers portent alors la même, et trier ou regrouper par date ne donne rien. Keo lit donc la
vraie date de prise de vue.

Mesuré avant d'être conçu : **4 Ko de préfixe suffisent** à lire `DateTimeOriginal`, en JPEG
comme en HEIC. Attention au piège — en HEIC il faut une source `CGImageSourceCreateWithData`,
car en mode incrémental non finalisé ImageIO refuse de parser les métadonnées HEIF et ne rend
rien, quel que soit le nombre d'octets fournis.

- À l'ouverture d'un dossier, les dates déjà connues sont appliquées **avant le premier rendu**.
- Les fichiers jamais vus sont analysés en tâche de fond, 6 en parallèle, 4 Ko chacun. Un
  dossier de 10 000 photos coûte donc environ 40 Mo, **une seule fois**.
- Le pipeline de vignettes enregistre la date au passage : il télécharge déjà 256 Ko par image,
  la lecture est gratuite.
- `CaptureDateIndex` persiste tout dans Application Support, y compris les fichiers **sans**
  date — sinon chaque visite les réanalyserait indéfiniment.
- Le réordonnancement n'a lieu **qu'à la fin du scan**, pas pendant : la grille ne se réorganise
  jamais sous le doigt. Une pastille discrète affiche l'avancement.

### L'index : SQLite, incrémental et durable

`Keo/Media/IndexStore.swift` — un actor propriétaire d'une connexion SQLite en WAL, dans
Application Support. `libsqlite3` est dans iOS, donc toujours aucune dépendance externe.

L'ancienne version était un dictionnaire JSON chargé entièrement en mémoire et **réécrit en
entier** à chaque sauvegarde. Le problème n'était pas la taille mais la granularité : l'unité
d'écriture était « tout l'index » et l'unité de perte « tout depuis la dernière sauvegarde ».
Un kill au milieu d'un dossier de 14 600 photos jetait six minutes de travail.

```sql
folder(id, path UNIQUE, mtime, child_count, media_count, bytes, gen)
file(folder_id, name, size, capture, gen)  PRIMARY KEY (folder_id, name, size)
INDEX file_by_identity ON file(name, size)
meta(k, v)
```

| Garantie | Comment |
|---|---|
| Durable à tout instant | WAL + `synchronous = NORMAL`. Un kill, un crash ou une batterie à plat ne corrompt rien |
| Perte bornée | Une transaction tous les 256 fichiers : au pire 256 lectures à refaire, pas un dossier entier |
| Cohérence du marquage | Le marquage « dossier terminé » part dans **la même transaction** que son dernier lot — il ne peut jamais prétendre plus que ce qui est écrit |
| Mémoire | Plus rien n'est chargé au démarrage ; une requête par dossier ouvert |
| Renommage gratuit | `file_by_identity` retrouve la date d'un fichier déplacé par `(nom, taille)`. Renommer un dossier de 14 600 photos coûtait des heures de relecture, c'est maintenant quelques millisecondes |
| Pas de gonflement | Compteur de génération : ce qui n'a pas été revu dans le listing est supprimé, les sous-arbres par cascade |
| Sous-arbres ignorés | Un dossier intact n'est pas listé, mais tout son sous-arbre voit sa génération avancer — sinon le balayage l'effacerait |

La clé `(dossier, nom, taille)` remplace `"chemin|taille"` : l'ancienne répétait 456 Ko de
préfixe de chemin sur le seul gros dossier.

**Migration** : les anciens `capture-dates.json` et `indexed-folders.json` sont repris au
premier lancement puis supprimés. Une indexation déjà payée ne se re-paye pas — c'est vérifié.

### La première fois

Tant que l'index est vide, Keo explique une fois pourquoi l'indexation compte : sans elle, le
NAS ne fournit que la date de copie, donc le tri par date et la timeline restent inertes — et
l'app a l'air cassée plutôt que non configurée. L'écran propose de lancer ou de remettre à
plus tard ; dans ce cas la pastille et le menu suffisent, on ne redemande pas.

### Un seul pipeline de lecture

`DateScan` et `Indexer` étaient deux boucles indépendantes qui pouvaient lire le même dossier
en même temps et doubler le trafic vers la box. Il n'en reste qu'une : une file sérielle que le
dossier affiché double par la tête, puisque c'est lui que quelqu'un attend.

Au-delà de **2 000 fichiers sans date**, un dossier ne se lit plus à l'ouverture : une pastille
renvoie vers l'écran d'indexation (menu « … » → *Indexation des dates*). L'indexation se met en
pause en arrière-plan et reprend au retour.

## Timeline

Quand le tri est par date, la grille se regroupe et un rail apparaît à droite.

- **En-têtes collants** par mois, avec le compte de photos. Un dossier qui tient dans un seul
  mois se regroupe par jour : sinon le regroupement n'apprendrait rien.
- Les dates viennent de l'EXIF dès que le scan ci-dessus est passé.
- **Rail de densité.** Chaque période reçoit un plancher de 5 pt avant que le reste soit
  réparti au prorata : en proportions pures, un mois creux devenait un trait d'un pixel,
  invisible et impossible à viser au doigt. Les libellés d'année s'écartent des bords et ne
  s'affichent qu'espacés de 26 pt, sinon ils se chevauchaient. La hauteur de chaque segment est la part de photos de la période, donc
  la forme du rail *est* la distribution — un long segment, c'est un mois où tu as beaucoup
  photographié. Les changements d'année sont étiquetés. On le glisse pour sauter directement.
- Le segment de la période à l'écran est mis en avant, via la position des en-têtes rendus.
- Les fichiers **sans date** forment une section en fin de liste plutôt que de disparaître.

Le rail s'efface en mode sélection, et le tri par nom revient à une grille continue sans
sections — y plaquer des mois n'aurait aucun sens.

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
| Mémoire des vignettes | Budget en **octets** (80 Mo), pas en nombre d'images, et purge sur alerte mémoire |
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
  Keo/Freebox/MediaSection.swift Keo/Media/DiskCache.swift Keo/Media/PreviewPolicy.swift \
  Keo/UI/MediaDate.swift Keo/UI/RailLayout.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
```

La géométrie du rail vit dans `RailLayout`, sans SwiftUI, précisément pour être vérifiable.
`Tests/store.swift` exerce le **vrai SQLite** sur un répertoire temporaire : écriture, balayage
des fichiers disparus, survie des sous-arbres ignorés, adoption après renommage, et migration
depuis les anciens JSON.

Couvre la garantie de lecture seule, l'enveloppe `{success, result}`, l'encodage des chemins,
la classification des médias, l'éviction LRU et l'arithmétique de progression.

## Pièges de l'API Freebox, vérifiés sur la box

- `fs/ls` renvoie `result = {"entries": [...], "cursor": "..."}`, **pas** un tableau nu.
- **`fs/ls` doit être paginé.** Mesuré sur un dossier de 14 600 fichiers : en un seul appel la
  box répond `504 Gateway Time-out` au bout de 15 secondes, systématiquement. Avec
  `?limit=2000` et le `cursor` renvoyé, le même dossier se liste en 2,9 s, et la première page
  arrive en ~200 ms. Le curseur est du base64 : `eyJvZmZzZXQiOjQ4Mn0=` = `{"offset":482}`.
- `filecount` n'est pas renvoyé par toutes les box — le compteur des tuiles de dossier s'efface
  quand il manque.
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
