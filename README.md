# Keo

Galerie photos/vidéos iOS native pour Freebox, via l'API Freebox OS.
SwiftUI, Swift 6 en concurrence stricte, aucune dépendance externe.

Ce fichier explique **pourquoi** le code est comme ça. `CLAUDE.md` dit **ce qui s'applique** :
la règle de lecture seule, la commande de vérification, les conventions, et les pièges qui ont
déjà coûté cher.

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

## Une seule association pour tous tes appareils

Le jeton d'application est marqué `kSecAttrSynchronizable` : le **trousseau iCloud** le porte
d'un appareil à l'autre. Un deuxième téléphone connecté au même compte Apple installe Keo,
l'ouvre, et se retrouve apparié sans que personne ne touche à la box.

**Rien à voir avec la synchronisation de la personnalisation plus bas.** Celle-ci est un miroir
CloudKit que l'app pilote ; le trousseau, lui, est un service système auquel l'app ne fait que
confier un item. Deux mécanismes, deux interrupteurs dans les Réglages, aucune dépendance entre
les deux : le trousseau coupé laisse les favoris se synchroniser, et l'inverse aussi.

Le compromis, assumé : la Freebox ne voit **qu'une seule autorisation**, partagée. Impossible
d'en révoquer une sans révoquer les autres. L'écran d'association le dit en une ligne, parce
qu'une autorisation partagée qu'on croit individuelle est une mauvaise surprise le jour où on
veut retirer l'accès à un appareil perdu.

Rien à configurer : pas de capacité à cocher, pas d'entitlement à ajouter — le groupe de
trousseau par défaut suffit. L'interrupteur existe déjà côté système (Réglages → compte →
iCloud → Mots de passe), et le couper ramène exactement au comportement d'avant : un jeton
local, une association par appareil.

### Ce qui est délicat, et ce que fait le code

- **`Synchronizable` fait partie de la clé primaire d'un item.** Une requête qui l'omet ne voit
  que les items locaux ; une requête qui le fixe à `true` ne voit que les synchronisés. Et un
  item ne se convertit pas sur place. Toutes les requêtes de `Keychain` passent donc par
  `kSecAttrSynchronizableAny` : une seule lecture, une seule suppression, qui trouvent le jeton
  quelle que soit sa nature — aucun appelant n'a changé.
- **La migration des jetons déjà posés** se fait à la lecture, le seul endroit par lequel tout
  le monde passe déjà. Si l'item trouvé n'est pas synchronisable, il est réécrit. C'est
  idempotent : un jeton déjà migré est lu et laissé tranquille.
- **L'ordre d'écriture est la garantie de non-perte.** On ajoute le synchronisé, et on ne
  supprime le local **qu'après** un `SecItemAdd` réussi. iOS ne dit pas si le trousseau iCloud
  est actif ; un échec, un appareil hors ligne ou un compte Apple absent ne coûtent donc rien,
  le jeton reste lisible et la tentative se répète au lancement suivant. Perdre le jeton
  coûterait un aller à la box — c'est précisément le bug déjà vécu une fois.
- **`kSecAttrAccessibleAfterFirstUnlock` est conservé.** Les classes en `…ThisDeviceOnly` sont
  refusées pour un item synchronisable, et refusées **en silence**. `AfterFirstUnlock` est la
  classe la plus stricte qui se synchronise encore, et c'est celle qu'il faut pour qu'un
  téléchargement repris en arrière-plan après un redémarrage puisse lire le jeton.
- **La déconnexion efface les deux natures**, toujours via `Any`. Sans ça, l'item local
  survivrait à la suppression du synchronisé et le jeton ressusciterait au lancement suivant.
- **Le jeton met parfois quelques secondes à arriver** sur un appareil qui vient de rejoindre le
  trousseau. L'écran d'association attend donc jusqu'à quinze secondes avant de renoncer, sans
  jamais bloquer le bouton : un tap dessus met fin à l'attente.
- **Le jeton est la seule chose stockée dans le trousseau** — `Keychain.set/get/delete` n'est
  jamais appelé avec un autre compte que l'hôte de la box. La question « que synchroniser
  d'autre » ne se pose donc pas ; le jour où elle se posera, elle se posera par secret, pas en
  bloc : le partage se justifie ici parce que l'autorisation est celle du foyer, pas celle de
  l'appareil.

### Vérifier à la main

Le scan de sources dans `Tests/main.swift` interdit les deux régressions qui échouent en
silence (une classe `ThisDeviceOnly`, une requête sans `Synchronizable`). Le reste exige deux
appareils et un vrai trousseau iCloud :

- **Migration** : sur un appareil déjà apparié par l'ancienne version, installer celle-ci et
  lancer. La galerie s'ouvre directement, sans écran d'association et **sans appui sur ✓**. Le
  jeton a été réécrit en silence.
- **Deuxième appareil, même compte Apple** : installer Keo, lancer. L'écran d'association
  apparaît, puis bascule tout seul sur la galerie en quelques secondes, box jamais touchée.
- **Trousseau iCloud coupé** (Réglages → compte → iCloud → Mots de passe) : l'appareil déjà
  apparié reste apparié, la galerie s'ouvre comme avant. Un nouvel appareil, lui, demande
  l'appui sur ✓ — comportement d'avant, pas une panne.
- **Hors ligne** : mode avion, désinstaller, réinstaller, lancer. Le jeton local ayant disparu
  avec l'app et le trousseau ne pouvant rien livrer, l'écran d'association s'affiche sans
  tourner en rond. Réseau rétabli, relancer : la galerie s'ouvre toute seule.
- **Deuxième compte Apple** : sur l'appareil signé avec l'autre compte, le jeton n'arrive pas.
  Appairer normalement — et vérifier que ce deuxième appairage ne casse pas le premier (la box
  autorise bien deux applications homonymes, elles ont des jetons distincts).
- **Déconnexion puis relance** : « Déconnecter » sur l'appareil A, tuer l'app, relancer :
  l'écran d'association reste, le jeton ne ressuscite pas. Puis relancer l'appareil B : lui
  aussi redemande l'association, ce qui est le compromis, pas un bug.
- **Révocation côté box** : Freebox OS → Gestion des accès → retirer Keo. Au lancement suivant,
  la validation par listing échoue, le jeton est effacé des deux natures et l'association
  normale reprend, sans boucle.

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

La phase est montée **sur les deux cibles**, Keo et KeoWidgetExtension. Le script travaille
sur `$TARGET_BUILD_DIR/$INFOPLIST_PATH`, donc il tamponne le bundle de la cible qui l'exécute,
sans rien changer d'autre. Ne la retirer d'aucune des deux : **iOS refuse d'installer une app
dont l'extension ne porte pas le même `CFBundleVersion` que l'hôte**, et l'app partirait en
build 42 avec un `.appex` resté à 1. L'échec est à l'installation, pas à la compilation.

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

## L'app parlait anglais sans le savoir

`CFBundleDevelopmentRegion` valait `en` et aucune localisation française n'était déclarée.
`Locale.current` résolvait donc en anglais **quel que soit le réglage de l'iPhone** : toutes
les dates formatées par l'app sortaient en anglais — « August 2011 » sous une interface
entièrement française. Visible seulement là où un mois s'écrit en toutes lettres, donc resté
invisible des mois.

Le bundle déclare maintenant `fr`, dans l'app comme dans l'extension widget.

## L'accueil

Ouvrir Keo tombait dans un listing de dossiers titré d'un nom d'hôte. Ce listing est le
meilleur navigateur de dossiers qu'une Freebox aura jamais — quinze ans de l'organisation de
quelqu'un — mais il n'a jamais été un accueil. Il reste, un onglet plus loin.

**Le principe, et c'est celui qui tient toute la refonte : l'âme ne se met pas dans le
chrome.** Les deux applications Apple les plus chaleureuses, Journal et Fitness, ont un chrome
rigoureusement standard. La chaleur vient d'ailleurs — du contenu de la personne, du langage,
et d'un seul personnage strictement rationné. Squelette système, chair personnelle.

L'accueil montre, dans l'ordre : **Ce jour-là** (les photos prises à cette date les années
passées, une page par année, le texte posé sur le dégradé de la photo elle-même — la couleur
de l'utilisateur, sans une ligne d'extraction de palette), les **dossiers épinglés**, les
**dernières photos par date de prise de vue** (ce qu'aucune galerie NAS ne fait honnêtement :
Plex et Jellyfin classent par date d'import, qui sur un NAS est la date de copie, précisément
le mensonge que cet index existe pour corriger), et la carte
**Bibliothèque**.

Tout sort de l'index local : cinq requêtes, pas la douzaine de `statistics`, parce que cet
écran s'ouvre à chaque lancement. La box peut rester éteinte toute la journée sans que
l'accueil cligne — ce qui est le but, puisqu'elle est sur le réseau de la maison et que le
téléphone n'y est pas, les deux tiers du temps.

### L'onglet Épinglés disparaît

Une épingle est un **accélérateur, pas une destination**, et garer un accélérateur dans un
emplacement de destination est exactement ce qui faisait que cet onglet sonnait faux — son
contenu n'était d'ailleurs qu'une liste de chemins, il n'y a jamais eu l'idée d'un écran
dedans. Les épingles deviennent l'étagère de l'accueil, *au-dessus de la ligne de flottaison*,
donc strictement plus accessibles qu'avant.

### La machinerie a une pièce à elle

Indexation, Statistiques et Déconnexion vivaient dans le menu de tri de chaque dossier. La
machinerie visible partout est la maladie qui fait qu'Immich ressemble à une console
d'administration. Elles sont dans la carte Bibliothèque, où l'état de l'indexation est
**visible en permanence** plutôt qu'à redécouvrir. Les surfaces contextuelles restent, parce
qu'elles sont justifiées par le contexte : les pastilles, et le bouton de la recherche.

### L'apparence suit le système

L'app forçait le mode sombre. Défendable pour une galerie — Lightroom fait pareil — mais
l'argument de Lightroom est un argument d'**étalonnage** : un entourage neutre pour juger des
couleurs qu'on corrige. Regarder des photos de famille n'est pas ça, et une surface noire à
midi dans la cuisine est une salle de cinéma, pas une maison. La marque avait d'ailleurs déjà
voté : `AccentColor` embarque une variante claire qui n'avait jamais été rendue une seule fois.

**La visionneuse reste noire**, épinglée sur elle-même et non à la racine de l'app : une photo
se regarde sur du noir quelle que soit la lumière de la pièce, et c'est ce que fait Photos.

Ce qui a dû changer : le rail de timeline peignait en `.white` sur un fond supposé noir, il
peint en `.primary` ; la mascotte, crème sur blanc, serait invisible — elle est devenue une
image *template* qui reçoit sa couleur au lieu de la porter, crème sur sombre et bleu de
marque sur clair. Les blancs restants sont tous posés **sur des photos**, où ils sont justes
dans les deux modes.

### La mascotte

La loutre en rendu 3D n'entre jamais dans l'app : de la fourrure photoréaliste à côté de SF
Symbols et de verre liquide se lit comme un écran-titre de jeu free-to-play, et ça daterait en
deux ans. Elle reste sur l'icône. La silhouette crème plate apparaît dans **trois endroits**,
tous des moments « l'app n'a encore rien de toi à montrer » : l'association, la carte de
bienvenue au premier lancement, et l'indexation jamais commencée. Jamais sur un écran qui
contient des photos — là, les photos gagnent.

## Structure

| Dossier | Rôle |
|---|---|
| `Keo/App/` | Entrée, `Store` (session, association), trousseau, tampon de build |
| `Keo/Freebox/` | `Item` et `FolderContents`, transports, client, asset vidéo authentifié |
| `Keo/Media/` | Pipeline de vignettes, décodage ImageIO, cache disque LRU, index des dates |
| `Keo/Downloads/` | File d'attente, pellicule, feuille de partage |
| `Keo/Sync/` | Miroir CloudKit de la personnalisation : identité des enregistrements, moteur |
| `Keo/UI/` | Accueil, association, grille, recherche, statistiques, visionneuse |
| `KeoWidget/` | L'extension WidgetKit. Ne lie que Foundation, SwiftUI, ImageIO et AppIntents |

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

Combien d'octets faut-il lire ? Mesuré sur **120 photos tirées au hasard d'une vraie
photothèque**, pas sur des fichiers fabriqués pour l'occasion :

| Premier palier | Dates trouvées | Requêtes/photo | Transfert moyen |
|---|---|---|---|
| 4 Ko | 38,9 % | 1,63 | 85 Ko |
| 16 Ko | 92,0 % | 1,13 | 33 Ko |
| **24 Ko** | **99,1 %** | **1,07** | **33 Ko** |
| 128 Ko | 100 % | 1,06 | 135 Ko |

Keo lit donc **24 Ko**, puis 128 Ko pour le dernier pour cent. Aucune photo de l'échantillon
n'a révélé sa date uniquement dans le fichier entier : ce que 128 Ko ne trouve pas n'existe
pas. Sur cet échantillon, 6 % des photos n'ont réellement aucune date — exports web, images
reçues, captures d'écran.

**`readerVersion`** : quand ce lecteur s'améliore, toutes les photos restées sans date sont
remises en file. Une date déjà trouvée n'est jamais rejetée. Sans ça, les 61 % manqués par le
palier à 4 Ko seraient restés faux pour toujours.

Attention au piège HEIC : il faut une source `CGImageSourceCreateWithData`, car en mode
incrémental non finalisé ImageIO refuse de parser les métadonnées HEIF et ne rend rien, quel
que soit le nombre d'octets fournis.

- À l'ouverture d'un dossier, les dates déjà connues sont appliquées **avant le premier rendu**.
- Les fichiers jamais vus sont analysés en tâche de fond, 3 en parallèle, 4 Ko chacun. Un
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
file(folder_id, name, size, capture, read, kind, gen)  PRIMARY KEY (folder_id, name, size)
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

### Ouverture instantanée

La base reflète le listing complet de chaque dossier déjà indexé — y compris les fichiers
jamais lus, d'où la colonne `read` qui distingue « vu » de « lu ». Un dossier déjà visité
s'affiche donc **avant que la box ait répondu**, puis se met à jour quand le vrai listing
arrive.

Deux conséquences assumées :

- La première page du listing live n'est plus affichée quand la grille vient déjà du cache :
  elle ferait rétrécir l'affichage avant de le regarnir.
- Si la box ne répond pas, un dossier déjà connu reste consultable au lieu d'afficher une
  erreur. Seul un dossier jamais vu montre l'échec.

### Un piège de migration de schéma

`ALTER TABLE ... ADD COLUMN kind INTEGER NOT NULL DEFAULT 0` a donné la valeur 0 à toutes les
lignes existantes — et 0 voulait dire « dossier ». Les photos déjà indexées revenaient donc du
cache comme des dossiers dans lesquels on pouvait entrer, et disparaissaient de la grille.

Trois corrections, parce qu'une seule n'aurait pas suffi :

- `isDirectory` décide seul de ce qui est un dossier. Un mimeType ne peut plus le faire, ce qui
  rend la classe de bug impossible plutôt que corrigée.
- Le défaut de la colonne devient 3 (« autre ») : **aucune valeur par défaut ne doit affirmer
  qu'un fichier est un dossier**.
- Les bases déjà écrites sont réparées à l'ouverture, le type étant redéduit du nom de fichier.

### Un seul pipeline de lecture

`DateScan` et `Indexer` étaient deux boucles indépendantes qui pouvaient lire le même dossier
en même temps et doubler le trafic vers la box. Il n'en reste qu'une : une file sérielle que le
dossier affiché double par la tête, puisque c'est lui que quelqu'un attend.

Au-delà de **2 000 fichiers sans date**, un dossier ne se lit plus à l'ouverture : une pastille
renvoie vers l'écran d'indexation (menu « … » → *Indexation de la bibliothèque*). L'indexation se met en
pause en arrière-plan et reprend au retour.

### Les dossiers techniques ne sont pas parcourus

Un NAS qui sert aussi de disque de travail contient des projets de développement, et un seul
`node_modules` fait des dizaines de milliers de fichiers répartis sur des milliers de
répertoires, dont pas un n'est une photo. Les parcourir coûtait des requêtes de listing à la
box, des lignes dans SQLite, du balayage à chaque fin de passage, et gonflait tous les compteurs
et tous les poids affichés sur les tuiles de dossier.

`Keo/Media/FolderExclusion.swift` tient la règle. Pure et hors SwiftUI, comme `LivePhotos` et
`WalkOutcome`, et pour la même raison : elle doit tenir à deux endroits — le parcours, qui ne
doit pas descendre, et le nettoyage de ce que les versions précédentes ont déjà indexé. Une
règle qui dérive entre les deux laisse des lignes que plus rien n'ira jamais supprimer.

| Exclu | Pourquoi |
|---|---|
| `node_modules` | npm, et la raison d'être du fichier |
| `__pycache__` | bytecode Python, souligné des deux côtés par l'interpréteur |
| `venv` | environnement virtuel Python ; `.venv` relève de la règle du point |
| `@eaDir` | la réserve de vignettes et d'index de Synology |
| `#recycle` | la corbeille de Synology |
| `$RECYCLE.BIN` | la corbeille de Windows, telle qu'elle apparaît sur un partage |
| `System Volume Information` | métadonnées de volume Windows, écrites sur tout partage |
| `lost+found` | ce que `fsck` recolle, jamais ce que quelqu'un a rangé |
| tout nom commençant par `.` | `.git`, `.svn`, `.venv`, `.build`, `.gradle`, `.next`, `.tox`, `.Trash`, `.Spotlight-V100`, `.fseventsd`, `.DS_Store`, `._*` |

La comparaison est **insensible à la casse** : un partage SMB l'est, donc `NODE_MODULES` et
`node_modules` désignent le même répertoire. Même raisonnement que `LivePhotos.key`.

La ligne sur le point mérite une note. `FreeboxClient.listPage` écarte déjà tout nom pointé
avant que la règle soit consultée, donc elle n'enlève rien de plus au parcours. Ce qu'elle
apporte : le nettoyage ci-dessous atteint les lignes qu'un ancien build a pu écrire, et la règle
reste **la** réponse à « Keo indexe-t-il ce dossier ? » plutôt que la moitié d'une réponse
répartie entre le transport et l'indexeur.

### Ce que la règle n'exclut délibérément pas

`build`, `dist`, `target`, `vendor`, `Pods`, `bin`, `obj`, `cache`, `tmp` — tous proposés, tous
refusés. Ce sont des mots ordinaires : « Build » peut être un dossier de chantier photographié,
« Vendor » un dossier de photos fournisseur. Les deux erreurs ne coûtent pas la même chose. Un
dossier indexé à tort, c'est quelques requêtes perdues sur un répertoire d'artefacts qui pèse de
toute façon mille fois moins qu'un `node_modules`. Un dossier exclu à tort, ce sont des photos
que le propriétaire ne retrouvera jamais, **sans le moindre message**. La liste reste donc
courte, et un nom n'y entre que si personne ne le donnerait à un dossier de photos.

La correspondance est exacte, jamais un sous-texte : `node_modules copie` et `mon-node_modules`
restent indexés. `Tests/exclusions.swift` épingle les deux sens.

Les dossiers exclus **restent consultables dans Parcourir** : on peut entrer dedans, les
fichiers s'affichent, ils se téléchargent. Seul l'index les ignore. Masquer serait une décision
plus lourde que celle qui est demandée ici, et impossible à rattraper du doigt.

### Pas d'écran de réglages

Ni liste modifiable, ni interrupteur. Huit noms qui ne peuvent pas être des dossiers de
photos, plus la règle du point, ne justifient pas un écran que personne n'ouvrira, et un réglage mal compris est exactement la
façon dont on perd des photos en silence. Le seul mode d'échec réel — une règle devenue trop
gourmande — est déjà visible : l'écran Indexation affiche **« Dossiers techniques exclus »**
avec le compte du passage, et la ligne s'ouvre sur les dix premiers chemins écartés. Une liste
d'exclusion silencieuse ressemble à un bug ; celle-ci se lit.

### Nettoyer ce qui est déjà indexé

Arrêter d'ajouter ne suffit pas : l'index du propriétaire contenait 4 799 dossiers et environ
48 000 fichiers, détritus de développement compris. `exclusionVersion` dans `meta` suit l'idiome
déjà en place (`listingVersion`, `liveVersion`, `readerVersion`) : au premier lancement qui voit
un numéro plus récent, `IndexStore` balaie une fois la table `folder` et supprime toute ligne
dont un composant du chemin est exclu. Les fichiers suivent par cascade (`ON DELETE CASCADE`,
avec `PRAGMA foreign_keys = ON`).

Ce que ça ne touche pas, et c'est structurel plutôt que déclaratif : **seule la table `folder`
est visée**. Les favoris, les collections, les raccourcis et les notes sont clavetés sur le
chemin et n'ont aucune clé étrangère vers `folder` — ils sont délibérément hors de la durée de
vie de l'index. Un favori posé *à l'intérieur* d'un `node_modules`, un raccourci vers ce dossier,
une note sur un de ses fichiers : tous survivent, et `Tests/exclusions.swift` le vérifie contre
le vrai SQLite, nettoyage rejoué deux fois pour montrer que la passe est idempotente.

Le filtre agit **avant** que le parcours descende, pas pendant : rien dans le cycle de vie de
l'indexation ne change, un sous-arbre n'y entre simplement jamais. C'est ce qui rend ce
changement sûr là où les autres pistes d'optimisation ne le sont pas.

## Recherche

Onglet dédié, porté par `TabRole.search` : iOS le range où il range la recherche partout
ailleurs — à part, à l'extrémité droite — au lieu d'enfoncer un cinquième onglet égal dans la
rangée. Les quatre autres passent en symboles non remplis (`symbolVariants = .none`), qu'une
barre d'onglets applique en `.fill` par défaut ; la rangée respire.

Et, et **une seule source : l'index local**. On n'interroge jamais la box.

Le marché est explicite : la recherche répond en quelques millisecondes, elle marche box
éteinte — et elle ne voit que ce qui a été indexé. Un dossier jamais parcouru n'apparaît pas.
L'écran le dit (« la recherche porte sur les N dossiers déjà indexés »), avec un bouton vers
l'analyse, plutôt que de laisser un « aucun résultat » mentir par omission.

### Accents

`LIKE` n'ignore la casse que pour l'ASCII : `Été` ne répondrait jamais à `ete`. On enregistre
donc une fonction SQL `fold()` sur la connexion (`registerFold`), qui replie casse et
diacritiques côté Swift. Le prix est un balayage de la table `file` au lieu d'un parcours
d'index — quelques millisecondes à notre échelle. Le plafond est noté dans le code : si l'index
grossit beaucoup, il faudra une colonne repliée et son index.

Les jokers SQL `%` et `_` sont échappés : un fichier peut légitimement s'appeler `100%_brut`.

### Les documents aussi

L'index ne retenait que les photos et les vidéos : un `Contrat.pdf` était compté dans le
poids du dossier et nulle part ailleurs. Il était donc introuvable, et absent d'une grille
peinte depuis le cache. Le parcours enregistre maintenant toute la liste, documents compris —
**enregistrés, jamais lus** : il n'y a pas de date de prise de vue dans un PDF, aller en
chercher les premiers kilo-octets n'achèterait rien.

Les dossiers déjà tamponnés resteraient complets pour toujours, donc leurs fichiers
n'apparaîtraient jamais. `listingVersion` efface les tampons une fois : chaque dossier est
relisté, aucun fichier n'est relu (`read = 1` n'est pas touché).

Un filtre de période exclut forcément les documents, qui n'ont pas de date. C'est voulu et
c'est dit par le filtre « Fichiers ».

### Retrouver l'endroit

Un résultat est montré dépouillé de son dossier, ce qui est précisément le repère qu'on veut
récupérer une fois qu'on l'a trouvé. Appui long sur n'importe quel résultat → « Aller dans
*…* ». Vaut aussi dans les Favoris et les Collections, qui perdent le même repère ; inutile
dans un vrai dossier, on y est déjà.

`BrowserSource.parent(of:)` est volontairement hors SwiftUI pour être vérifiable : elle rend
`nil` à la racine et pour tout chemin qu'on ne sait pas découper, jamais un dossier inventé.

### Période

Un seul axe, trois états : toutes les périodes, une année, ou un intervalle entre deux dates.
Pas une année *et* une plage côte à côte — deux contrôles qui restreignent la même chose
finissent par se contredire. `SearchQuery.Period` porte les trois cas et calcule lui-même la
fenêtre en secondes : bornes inclusives, journées entières (mêmes dates aux deux bouts = cette
journée, pas cet instant), et bornes remises à l'endroit si elles sont inversées.

### Dossiers

Un dossier remonte sur **son nom**, jamais sur son chemin : chercher `Photos` ne doit pas
retourner les deux cents sous-dossiers de `/Photos`. Un dossier qui matche remonte aussi ce
qu'il contient. Les filtres de type et de période excluent les dossiers, qui n'ont ni l'un ni
l'autre.

Les résultats passent par le même `BrowserView` que le reste (`BrowserSource.results`) : même
grille, même visionneuse, même sélection, mêmes téléchargements.

## Photos live

Une photo live d'iPhone copiée sur un NAS arrive en deux fichiers ordinaires :
`IMG_4821.HEIC` et `IMG_4821.MOV`, même racine, même dossier. L'appariement qu'iOS tenait
dans les métadonnées `PHAsset` est perdu à la copie, et rien dans les fichiers ne dit qu'ils
vont ensemble. Résultat : une bibliothèque qui paraît deux fois plus pleine qu'elle n'est, et
un jumeau gris à côté de chaque photo.

Keo les réunit sur la seule preuve qui reste, le nom. Le `.MOV` disparaît de la grille ; en
plein écran, un bouton dans la barre du bas joue la vidéo — muet, une passe, retap pour
arrêter. Sa seule présence dit que la photo en a une : la pastille « LIVE » en haut à gauche
qui le disait avant a été retirée, elle était laide et redondante.

Deux essais ont précédé ce bouton, et les deux ont échoué au doigt. **L'appui long**, à la
Photos : on ne sait pas combien de temps tenir ni si quelque chose se passe. **La pastille
elle-même comme bouton** : en haut à gauche, c'est l'angle le plus éloigné du pouce. D'où la
règle déjà écrite dans le code — *« Bottom: everything you actually do, within thumb reach »*
— appliquée aussi ici.

La barre passe donc à **cinq emplacements de largeur égale** au lieu d'un espacement fixe, et
le cinquième reste vide sur une photo sans vidéo. Ne le poser que lorsqu'il existe ferait
glisser le cœur hors du pouce en passant d'une photo live à une photo ordinaire.

### Le nom ne suffit pas : l'identité d'Apple

Un cas réel l'a montré : un `IMG_0988.HEIC` et un `IMG_0988.MOV` sans aucun rapport, fondus en
un seul moment parce que les compteurs de l'iPhone repassent par les mêmes numéros. Une vraie
vidéo disparaissait en silence.

Apple écrit un **UUID partagé** dans les deux moitiés d'une photo live — MakerNote 17 côté
image, `com.apple.quicktime.content.identifier` côté vidéo — et Photos lui-même exige leur
égalité. Le nom de fichier n'est qu'une convention posée par-dessus. L'appariement devient
donc une identité, et le nom ne sert plus qu'à désigner les candidats.

**Mesuré avant d'être écrit**, deux fois :

- Sur 120 photos tirées au hasard : identifiant présent dans **80,8 %**, et le chiffre est
  *identique* à 24 Ko et à 128 Ko. Ce n'est donc pas une troncature — une photo ordinaire n'a
  simplement pas d'identifiant. (La date, elle, est à 95,0 % puis 96,7 %.)
- Sur 60 **vraies paires** : 57 identiques, **0 contradiction**, 3 avec un identifiant d'un
  seul côté.

### Pourquoi le silence ne dé-apparie pas

La recommandation disait qu'un seul côté porteur suffit à refuser la paire, une vidéo de photo
live en portant toujours un. La mesure impose la prudence : le sondage ne sait pas distinguer
« lu, pas d'identifiant » d'« échec de lecture ». Dé-apparier sur un silence aurait coûté des
paires correctes pour n'acheter rien — le cas signalé porte un identifiant **des deux côtés**.

La règle est donc : **seule une contradiction explicite refuse la paire**. Les deux moitiés
lues, les deux porteuses, et les deux différentes. Tant qu'un côté n'a pas été lu, la règle du
nom s'applique exactement comme avant : pas de jour J, l'index converge au fil des lectures.

**L'appariement n'a jamais franchi les frontières d'un dossier** : la règle exige le même
`folder_id` côté SQL, et ne travaille que sur les médias d'un seul dossier côté Swift. Le cas
réel venait d'ailleurs — **deux iPhone différents** dont les compteurs repassent par les mêmes
numéros, et dont les photos ont fini dans un même dossier.

Sur l'ensemble de la bibliothèque, une fois la migration passée : **13 882 paires concordantes,
71 contradictions, 227 avec un seul côté porteur, 40 sans aucun identifiant**. Les 71
contradictions sont 70 vraies vidéos qui étaient masquées derrière une photo sans rapport.

Le coût est borné par construction — seule une vidéo dont le nom correspond à une photo du
même dossier est candidate. Côté photo, l'identifiant arrive dans le préfixe déjà lu : gratuit.

**Un `.MOV` isolé reste une vidéo visible.** C'est tout ce qui n'a pas été pris à l'iPhone, et
le masquer le perdrait.

La règle vit dans `LivePhotos`, hors SwiftUI, parce qu'elle doit tenir à trois endroits — un
listing frais venu de la box, un listing rejoué depuis l'index, et le `UPDATE` qui marque la
base — et qu'une règle qui dérive entre eux montre la vidéo d'un côté et la cache de l'autre.
Côté SQL c'est la même fonction, enregistrée sur la connexion sous le nom `stem`, comme
`fold` pour les accents.

### Le cache rend tout, la grille applique la règle

`IndexStore.listing` renvoie le compagnon avec le reste, et c'est `FolderContents` qui le
masque — le même code que pour un listing frais venu de la box. Filtrer en SQL paraissait plus
propre, mais un dossier ouvert depuis le cache n'avait alors aucun `.MOV` à apparier : pas de
pastille « live », pas de lecture au doigt, jusqu'à ce que la box réponde. Deux chemins, deux
comportements, pour une règle censée être unique.

La colonne `live` sert aux requêtes qui n'ont pas de `FolderContents` sur quoi s'appuyer : la
recherche, les couvertures de tuiles, les photos du widget, les compteurs.

### Ce qui est caché reste indexé

Masquer un fichier de la grille ne doit jamais le masquer de l'index : le balayage
l'effacerait, et la visionneuse n'aurait plus de vidéo à jouer. Les compagnons sont donc
enregistrés — mais **jamais lus** : leur date de prise de vue est celle de la photo, aller la
chercher coûterait des requêtes pour rien.

Ils comptent aussi dans le **poids** du dossier, qui doit dire ce que le NAS occupe, pas ce
qui est visible. Le compteur de médias, lui, compte les moments : une photo live, c'est un.

La migration ne relit rien sur le NAS. Un seul `UPDATE` sur la table `file` marque tous les
dossiers déjà indexés au premier lancement, gouverné par `liveVersion`.

## Annuler

Retirer trois favoris d'un coup les sortait de la liste instantanément, et la liste était le
seul endroit où ils existaient : plus rien pour les retrouver. Rien de tout cela ne touche au
NAS, donc rien n'est dangereux — mais c'est **irrécupérable**, ce qui à l'usage est pire.

Un bandeau *et* un secouage, délibérément les deux. Le secouage est le mécanisme iOS, mais
personne ne le découvre : seul, la fonctionnalité existerait sans exister. Le bandeau la rend
visible ; le secouage laisse remonter plus loin, jusqu'à huit pas en arrière.

Sont annulables : les favoris (ajout comme retrait, sélection multiple comprise), l'ajout à une
collection, l'épinglage d'un dossier, et l'écriture ou l'effacement d'une note. Pour la note,
le texte précédent est capturé **avant** l'écriture : vider le champ supprime la ligne, et il
ne resterait rien à relire.

Un glissement vers le bas le chasse sans attendre les cinq secondes. L'étape reste sur la
pile — le secouage l'annule toujours — le bandeau a simplement cessé de réclamer l'attention.

Le bandeau est posé à deux endroits — au-dessus de la barre d'onglets, et à nouveau dans la
visionneuse. Un `fullScreenCover` est dessiné par-dessus la racine, donc une superposition
posée sur la racine serait invisible depuis la photo.

### Un seul endroit qui sait que quelque chose a changé

Les marqueurs d'une vignette — favori, collection, note — sont lus une fois par chargement.
Chaque écran rafraîchissait donc les siens là où l'action se produisait, ce qui marchait tant
que l'action se produisait là : mettre un favori depuis le plein écran laissait la grille
derrière avec les anciens marqueurs, et une annulation ne rafraîchissait rien du tout.

Toute modification de la personnalisation passe déjà par l'`Undoer` pour être réversible.
C'est donc lui qui porte un numéro de révision, et chaque écran le regarde. Une seule source,
au lieu d'un rafraîchissement à recopier à chaque nouvel appel.

Le capteur de secouage est un premier répondeur de taille nulle, faute de geste de secouage en
SwiftUI et parce que les alternatives sont le *swizzling* de `UIWindow` ou une liste de
fenêtres dépréciée. Il cède le premier répondeur dès qu'un champ de texte le réclame, ce qui
est le comportement voulu : pendant qu'on tape, un secouage appartient à l'annulation du champ.

## Notes

Une note sur une photo, une vidéo ou un dossier. C'est la seule personnalisation dont le
**contenu** change, et ça change tout pour la synchronisation : pour un favori, la présence
suffit à trancher un conflit, donc `INSERT OR IGNORE` règle tout. Deux appareils peuvent en
revanche détenir des *textes différents* pour la même note. La ligne porte donc son propre
`modified`, et le gardien est dans l'instruction SQL elle-même :

```sql
ON CONFLICT(path, size) DO UPDATE SET body = excluded.body, modified = excluded.modified
  WHERE excluded.modified > note.modified
```

Une édition plus ancienne qui arrive en retard ne peut pas écraser une plus récente. Le rejeu
du journal réémet la date de la note, jamais celle du rejeu — sinon une note périmée passerait
pour la plus fraîche.

Une note vidée est une note **supprimée**, pas une ligne contenant `""` que la recherche
remonterait sur n'importe quelle requête.

Rien n'est écrit sur le NAS : un fichier d'accompagnement à côté de la photo serait une
écriture, et c'est précisément ce que l'app ne fait jamais. Les notes vivent dans l'index,
à côté des favoris, et passent par le même miroir CloudKit.

La note fait partie du texte de l'élément pour la recherche : écrire « facture EDF » sur une
photo est le seul moyen de retrouver un fichier qui s'appelle `IMG_4821.HEIC`.

### Le piège de la racine

Le périmètre d'un sous-arbre s'écrivait `substr(path, 1, length(?1) + 1) = ?1 || '/'`. À la
racine, `?1` vaut `/` et l'expression cherche des chemins commençant par `//` — aucun. Deux
bugs vivants en découlaient, découverts en écrivant les statistiques : `hasChildFolders("/")`
répondait « aucun enfant » (ce qui autorise l'indexeur à sauter un dossier d'emblée), et
`listing("/")` ne rendait aucun sous-dossier, donc la racine s'affichait vide tant que la box
n'avait pas répondu.

Le préfixe se calcule maintenant en Swift (`Statistics.scopePrefix`) et se lie en paramètre.
Mais la correction évidente en réintroduit un autre dans l'autre sens : à la racine, `/`
satisfait son propre préfixe, et la racine s'est mise à figurer **parmi ses propres
sous-dossiers** — une tuile dans laquelle on entrait indéfiniment. D'où la garde de longueur,
`length(path) > length(?1)`, qui rend « strictement à l'intérieur » vrai dans les deux cas.
`Tests/stats.swift` épingle les trois comportements.

## Favoris, collections, raccourcis

Deux niveaux, parce qu'ils répondent à deux gestes différents :

- **Favoris** — un cœur, un tap, depuis le plein écran ou le mode sélection. Pas de choix à
  faire quand on veut juste marquer une belle photo.
- **Collections** — un choix délibéré, en deux temps. Une photo peut être en favori **et**
  dans plusieurs collections.
- **Raccourcis** — des dossiers épinglés par appui long sur leur tuile, avec leur chemin
  parent et les totaux que l'index a déjà comptés.

Quatre onglets : **Parcourir · Raccourcis · Favoris · Collections**.

Un tiroir latéral aurait été la forme évidente, et c'est précisément ce que les guidelines
d'Apple écartent : une navigation cachée derrière une icône est une navigation que personne ne
trouve. Les onglets sont ce que Photos utilise pour le même découpage. Retaper l'onglet actif
remonte à sa racine, et sur iOS 26 la barre se réduit au défilement pour ne rien voler à la
grille.

Le mot « collection » est délibéré : **rien n'est créé sur le NAS**. « Album » laisserait croire
qu'un dossier a été écrit sur la box, ce que Keo ne fait jamais.

### Quand un favori disparaît du NAS

Rien n'est purgé dans le dos de l'utilisateur. La règle est de distinguer **« absent »** de
**« inconnu »** :

- Un fichier dont le dossier n'a **jamais été lu entièrement** est inconnu, pas disparu. Le
  condamner cacherait des photos parfaitement valides.
- Un fichier absent d'un dossier **portant un marquage de complétion** est réellement parti.
- Un fichier retrouvé ailleurs **sous le même nom et la même taille** a bougé, pas disparu :
  son chemin est corrigé en silence et persisté. L'identité de synchronisation dérivant du nom
  et de la taille, ce déplacement ne génère aucun trafic entre appareils.
- Plusieurs correspondances : on ne devine pas, même doctrine que l'adoption des dates.

Les introuvables s'affichent dans un bandeau qui annonce leur nombre, et leur retrait reste
**un geste délibéré**. Les raccourcis suivent la même règle, marqués d'un signe orange.

### Elles survivent à l'index, pas l'inverse

`favourite`, `shortcut`, `collection` et `collection_item` sont **clés sur le chemin**, pas sur
une ligne de l'index. Un balayage, un « Tout relire depuis zéro », ou un dossier injoignable un
soir ne doivent jamais emporter les favoris de quelqu'un. C'est vérifié : les checks effacent
tout l'index et exigent que favoris, collections et membres soient toujours là.

Elles sont aussi la seule chose qui mérite de survivre à l'appareil : c'est exactement ce que
la synchronisation iCloud ci-dessous miroite — et rien d'autre.

Une collection emprunte à l'index la date de prise de vue qu'il connaît déjà, donc elle se
trie et se regroupe exactement comme un dossier.

## Synchronisation iCloud de la personnalisation

`Keo/Sync/` miroite les quatre tables de personnalisation — `favourite`, `shortcut`,
`collection`, `collection_item` — dans la base **privée** CloudKit, via `CKSyncEngine`.
Framework système, donc toujours zéro dépendance. L'index, lui, **n'est pas synchronisé** :
il est volumineux et se reconstruit depuis le NAS ; la personnalisation, elle, est
irremplaçable et pèse quelques centaines de Ko.

**SQLite reste la source de vérité.** CloudKit est un miroir, et le moteur ne décide jamais
rien : il pousse ce que le journal lui donne et applique ce qu'il reçoit.

Trois idées portent tout le reste :

- **`recordName` déterministe** (`SyncModel.swift`) : le nom d'un enregistrement est un hash
  stable de l'action de l'utilisateur — « ce fichier est un favori », « ce dossier est
  épinglé ». Deux appareils qui ajoutent le même favori écrivent *le même* enregistrement :
  l'ajout est idempotent et le conflit de doublon disparaît par construction. Une collection
  est identifiée par son **nom** ; la renommer est donc une suppression de l'ancienne
  identité plus une création de la nouvelle, membres compris — coûteux en enregistrements,
  mais deux appareils qui créent « Vacances » chacun de leur côté n'en font qu'une.
- **Un journal de changements** (`sync_pending` dans `IndexStore`), écrit **dans la même
  transaction** que le changement qu'il reflète. Un kill ne peut donc ni perdre une
  modification ni en inventer une : la ligne survit jusqu'à l'acquittement du serveur, et la
  renvoyer est inoffensif puisque le nom est déterministe. Une ligne par enregistrement —
  ajouter puis retirer se replie sur la dernière opération. Appliquer un changement *reçu*
  ne passe jamais par le journal : c'est ce qui interdit à deux appareils de se renvoyer le
  même changement pour toujours.
- **Dernier écrivain gagne, par enregistrement, avec un biais assumé vers la résurrection.**
  Une suppression distante est ignorée tant qu'un ajout local n'est pas encore poussé ; un
  ajout distant annule une suppression locale en attente. Dans les cas tordus, un favori
  réapparaît plutôt qu'il ne disparaît : un favori en trop se re-supprime en un tap, un favori
  perdu en silence est irrécupérable. Les horloges ne départagent que deux *ajouts* du même
  enregistrement — dont le contenu est identique par construction, l'identité étant dans la
  clé — donc une horloge décalée peut au pire choisir la date d'ajout de l'autre appareil,
  jamais perdre un favori.

### Les cas limites, et ce que fait le code

| Cas | Réponse |
|---|---|
| Pas de compte, iCloud coupé pour Keo, contrôle parental | `status = .off`, l'app est exactement l'app d'avant, en local, avec une ligne discrète en bas des onglets de personnalisation. Jamais de dialogue |
| Changement de compte iCloud | L'identifiant du compte est mémorisé dans `meta`. Un **autre** compte qui arrive efface la personnalisation et le journal (`wipePersonalisation`) : on ne mélange jamais deux personnes, ni en poussant les données de l'un chez l'autre, ni l'inverse. Une **déconnexion** n'efface rien : les données restent locales |
| Hors ligne prolongé | Le journal accumule, replié par enregistrement ; au retour, `CKSyncEngine` pousse et les noms déterministes absorbent les doublons |
| App tuée avec des envois en attente | Le journal est dans la transaction du changement ; l'état du moteur est persisté (`sync-state.json`). Une ligne ne sort du journal qu'à l'acquittement, et seulement si elle n'a pas été réécrite pendant l'aller-retour |
| Réinstallation | Tant que la première récupération n'est pas terminée (`syncFetched`), un onglet vide affiche « Récupération en cours » au lieu de « Aucun favori » : vide-parce-que-rien-n'est-arrivé n'est pas vide-parce-qu'il-n'y-a-rien |
| Premier lancement avec des données locales (l'utilisateur actuel) | `seedSyncJournalIfNeeded` journalise tout l'existant, une fois (`syncSeeded`). Les noms déterministes garantissent zéro doublon côté serveur |
| Zone supprimée dans Réglages → iCloud → Stockage | Le local est la source de vérité : la zone est recréée et tout re-remonte — sans transformer les suppressions en attente en ajouts |
| Quota plein | Message discret, le journal garde tout, ça repart quand la place revient |
| `retryAfter`, débit limité, jeton de changement expiré | Gérés par `CKSyncEngine` lui-même — c'est la raison de ce choix |
| `serverRecordChanged` | Dernier écrivain gagne ; si le local gagne, le nouvel essai est construit **sur** l'enregistrement serveur (system fields archivés dans le journal) pour ne pas re-collisionner |
| Renommage contre renommage d'une collection | Chacun étant suppression + création, il reste les deux collections, avec les mêmes membres : visible et réparable en un geste, plutôt qu'un des deux renommages perdu en silence |
| Suppression contre ajout de membre | L'ajout gagne : un membre reçu pour une collection disparue la recrée |
| Boucle de suppression | Impossible : l'application d'un changement distant ne journalise rien, donc rien ne repart |

### Configuration — ce que le propriétaire doit faire à la main

Le dépôt contient déjà `Keo/Keo.entitlements` (CloudKit, conteneur
`iCloud.com.oasutalab.keo`, `aps-environment`, groupe d'app) et le mode background
`remote-notification`. Le build **simulateur** passe tel quel. Pour un appareil, une fois,
dans Xcode avec le compte de l'équipe ton équipe Apple :

1. Cible Keo → *Signing & Capabilities* → vérifier que les capacités **iCloud → CloudKit**
   (conteneur `iCloud.com.oasutalab.keo`) et **Push Notifications** apparaissent ; la
   signature automatique enregistre alors l'App ID et crée le conteneur.
2. Premier lancement en debug : le schéma (type `Personalisation`, champs chiffrés) se crée
   tout seul dans l'environnement **Development** au premier enregistrement.
3. Avant toute distribution : [CloudKit Console](https://icloud.developer.apple.com) →
   conteneur → *Deploy Schema Changes* vers **Production**. Sans ce clic, une build
   TestFlight/App Store ne peut rien écrire.
4. **Groupe d'app, pour le widget.** Cibles **Keo** *et* **KeoWidgetExtension** →
   *Signing & Capabilities* → **App Groups** doit lister `group.com.oasutalab.keo`. Les deux
   fichiers d'entitlements le déclarent déjà ; ce qui manque est son enregistrement côté App
   ID, et c'est ce clic qui le fait.

   `xcodebuild` ne sait pas le faire : en ligne de commande la build échoue sur
   « *Provisioning profile … doesn't include the App Groups capability* » pour les deux
   cibles, tant que Xcode n'a pas été ouvert une fois. Ce n'est pas un défaut du projet — la
   compilation et l'assemblage passent (`CODE_SIGNING_ALLOWED=NO` le montre), seule la
   signature attend ce passage par l'interface.

### Vérifier le reste à la main

Tout ce qui est pur — noms, journal, acquittements, résurrection, renommage, graine, zone,
changement de compte — est couvert par `Tests/sync.swift`. Ce qui exige le vrai iCloud ne se
simule pas :

- **Deux appareils**, même compte : favori ajouté sur A → apparaît sur B en quelques
  secondes ; supprimé sur B → disparaît sur A sans revenir.
- **Hors ligne** : mode avion sur A, dix modifications, mode avion sur B, modifications
  contradictoires, puis réseau : convergence sans doublon, le favori contesté survit.
- **Kill** : modifier puis tuer l'app depuis le sélecteur avant la synchro ; relancer : la
  modification part quand même, une seule fois (visible dans la CloudKit Console).
- **Réinstallation** : supprimer l'app, réinstaller : « Récupération en cours » puis tout
  revient.
- **Zone supprimée** : Réglages → compte → iCloud → Stockage → Keo → Supprimer les données ;
  au lancement suivant tout re-remonte.
- **Changement de compte** : se déconnecter d'iCloud (les données restent), se connecter avec
  un autre compte (elles s'effacent, celles de l'autre compte arrivent).

### Migration et refus

Rien à migrer : les tables locales ne changent pas, le journal s'y ajoute. Au premier
lancement avec un compte, l'existant remonte tout seul (la graine ci-dessus). Pas de réglage
dans l'app : iOS fournit déjà l'interrupteur (Réglages → compte → iCloud → Keo), et le couper
ramène simplement au comportement d'avant — tout local, rien de perdu, le journal attend. Le
retirer du système pour le redonder dans l'app serait un deuxième endroit où se tromper.

## Widget

**L'app pré-rend, le widget ne fait qu'ouvrir des fichiers.** L'extension ne lie que
Foundation, SwiftUI, ImageIO et AppIntents. Pas d'entitlement de trousseau, aucune socket,
jamais de SQLite.

L'autre option aurait été de partager l'index par App Group. Elle est écartée pour une raison
simple : **l'index ne contient aucun pixel.** Il stocke `(folder_id, name, size, capture,
read, kind, gen)` — des chemins et des dates. Le partager ferait migrer la base irremplaçable
du propriétaire pour n'y gagner qu'un nom de fichier et un flou. Et `IndexStore.open()`
exécute huit écritures avant son premier `SELECT` : quatre `ALTER TABLE`, un `UPDATE`, puis
`retryDatelessAfterReaderChange`, `repairKinds` et `migrateFromJSON` — sans compter le
`CREATE TABLE` du schéma. Une extension de 30 Mo que le système peut tuer en pleine
transaction ne doit jamais faire tourner ça.

Les seuls pixels qui existent sont des vignettes de 400 px dans `Caches/`, purgeable et évincé
en LRU par l'app elle-même, et seulement pour les photos déjà défilées.

### Pourquoi pas de réseau dans l'extension

1. L'app est **LAN uniquement**, et le téléphone est hors du Wi-Fi de la maison les deux tiers
   de la journée. Un widget réseau passerait sa vie à afficher un échec.
2. Partager le jeton voudrait dire un `keychain-access-groups` et réécrire l'élément sous un
   nouveau groupe. Perdre ce jeton coûte un déplacement physique devant la face avant de la
   Freebox, et c'est déjà arrivé une fois. Par ailleurs `Keychain.service` vaut
   `Bundle.main.bundleIdentifier`, soit `com.oasutalab.keo.KeoWidget` dans l'extension :
   elle chercherait en silence dans le mauvais service.
3. 30 Mo pour tout le processus, quand `ThumbnailPipeline.still()` peut retomber sur un
   téléchargement de 40 Mo.
4. `NSLocalNetworkUsageDescription` dans un `.appex` lève un **second** dialogue de
   permission, attribué à quelque chose que le propriétaire ne voit pas.
5. Une extension sans `FreeboxClient` ne peut pas écrire sur le NAS, même par accident.

### Ce que l'app écrit

Au premier plan, avec un client vivant, `WidgetRenderer` prend les douze captures les plus
récentes du **sous-arbre** de chaque dossier épinglé, les passe par le pipeline de vignettes
existant en 1200 px, et écrit le tout dans `group.com.oasutalab.keo/Widget/` :

```
Widget/widget.json                  le manifeste, écrit en atomique
Widget/<sha256(chemin)>/<sha256(chemin du fichier)>
```

Les noms sont hachés parce qu'un chemin du NAS n'est pas un nom de fichier : il porte des
slashes et pourrait porter des `..`. L'extension joint donc de l'hexadécimal plat, qui ne peut
pas remonter hors du conteneur.

- Protection `completeUntilFirstUserAuthentication`, **pas** `complete` : le widget se
  rafraîchit téléphone verrouillé, et des fichiers illisibles le videraient à chaque fois.
- Le rendu est **sauté entièrement pendant que l'`Indexer` tourne** — c'est volontairement un
  lecteur série unique, un second ramènerait le trafic doublé qu'on avait justement supprimé.
- Une fois par heure, **sauf si l'ensemble des épingles a changé** : épingler un dossier ne
  doit pas attendre une heure pour s'afficher.
- Les dossiers désépinglés et les photos sorties du top 12 sont retirés du conteneur au
  passage ; sinon il grossirait indéfiniment.

### La liste des dossiers

Elle vient de la table **`shortcut`** — des dossiers que le propriétaire a déjà choisis par
appui long sur leur tuile. Curée, typiquement moins de cinquante entrées, aucune nouvelle
interface, et le coût du rendu est borné par construction. Si un dossier n'est pas proposé, la
réponse tient en un appui long ; la feuille de réglages du widget le dit.

La configuration passe par un `EntityQuery`, pas un `DynamicOptionsProvider` : le choix doit
persister par une identité stable — le chemin Freebox — et être re-résolu quand la liste
change. Un fournisseur d'options stocke la valeur au lieu d'une référence et rancit dès le
premier épinglage.

`widgetAccentedRenderingMode(.fullColor)` est obligatoire : sans lui le mode teinté de l'écran
d'accueil aplatit les photos en silhouettes blanches. Pour un widget photo, c'est un bug.

### Les quatre widgets, et ce que montre chaque taille

Une photo nue ne dit pas de quel dossier elle vient — « on voit juste la dernière photo du
dossier plutôt que le nom du dossier ». Chaque taille porte donc son texte, sur un dégradé
sombre en bas de l'image : pas une ombre, qui disparaîtrait sur un ciel blanc.

| Taille | **Keo** (un dossier) | **Ce jour-là** | **Raccourcis Keo** |
|---|---|---|---|
| Petit | Une photo, le nom par-dessus. Pas de place pour autre chose | Une photo, « il y a 7 ans », la date | *non proposé : une tuile seule, c'est déjà le widget de dossier* |
| Moyen | Une photo, le nom et la ligne de contexte | Trois photos côte à côte, chacune son « il y a N ans » | Trois tuiles : photo la plus récente du dossier, son nom |
| Grand | Mosaïque : une vedette, trois en bandeau | Vedette plus bandeau, chaque cellule datée | Deux rangs de trois tuiles |

La ligne de contexte est « 14 595 photos · 2009 – 2024 ». Ses deux moitiés sont optionnelles
dans le manifeste, et **omises** quand elles manquent : sur un dossier que l'index n'a pas
fini, le compte est réellement inconnu, et retomber sur le nombre d'images donnerait douze —
les couvertures pré-rendues, pas le dossier. Jamais de zéro, jamais d'estimation.

Mosaïque = une vedette plus un bandeau, et non une grille fixe, parce que le bandeau
raccourcit tout seul quand le dossier offre moins de photos : quatre cellules, puis trois,
puis deux, puis la vedette seule. Une grille aurait dû répéter une photo pour rester carrée.

**« Ce jour-là »** est le seul des trois dont le contenu est différent demain, donc le seul
qui donne une raison de regarder l'écran d'accueil. Il n'a pas d'intent de configuration : un
jour ne se choisit pas, c'est aujourd'hui. Trois états plutôt qu'un :

- des photos, avec « il y a N ans » **calculé** à partir de l'année — stocker la phrase
  ferait dire « il y a 7 ans » en janvier à un widget archivé le 31 décembre ;
- rien aujourd'hui, ce qui est le cas de la plupart des jours d'une photothèque modeste :
  « Rien ce jour-là dans les années passées », dit platement, pas déguisé en erreur ;
- un manifeste qui ne date pas d'aujourd'hui — passé minuit, ses souvenirs sont ceux d'hier :
  « Ouvre Keo pour les photos d'aujourd'hui », plutôt que les photos d'hier sous la date
  d'hier. La timeline s'arrête donc à minuit, puisque c'est à minuit que la réponse change.

Le quatrième, **« Index Keo »**, n'est pas un widget photo et ne vit que sur l'écran
verrouillé — la section suivante dit pourquoi.

### « Index Keo » : le seul chiffre qui bouge

Le brief tenait en une phrase : « un widget de statistiques peut être sympa ». La recherche
qui a produit l'écran de statistiques était pourtant franchement hostile aux chiffres de
vanité, avec une règle simple — *chaque chiffre affiché est un appui vers une grille ou un
dossier ; un chiffre sur lequel on ne peut rien faire ne sort pas*. Un widget ne se tape pas
vers une grille, il ne sait qu'ouvrir un lien. « 48 212 fichiers » sur l'écran d'accueil
serait exactement la décoration que cette recherche refuse.

**Ce qui a été écarté, et pourquoi :**

- **Les totaux** — nombre de fichiers, poids, étendue, première photo. Déjà rejetés dans
  l'app (« il ne survit que comme dénominateur du bandeau : seul, il flatte sans rien
  apprendre »), et un widget ne les rend pas meilleurs.
- **« ~23 Go récupérables · 1 940 doublons probables »**, pourtant la piste la plus
  séduisante. Deux raisons de la refuser. D'abord, l'honnêteté de ce chiffre *est* sa réserve
  — « même nom et même taille, ce n'est pas une empreinte », quatre lignes de pied de section
  dans l'app. Un petit widget a de la place pour le nombre et aucune pour la réserve, et un
  chiffre dont on a retiré la réserve est précisément un chiffre qu'il ne faut pas croire.
  Ensuite, Keo n'écrira jamais sur le NAS : l'« action » se résume à aller regarder une liste
  puis à supprimer ailleurs. Une corvée affichée tous les jours sans moyen de l'exécuter
  n'est pas de l'actionnable, c'est du mobilier culpabilisant.
- **Le jour le plus photographié, l'année qui ressort.** Ce sont des records historiques : ils
  ne changent plus. Et la seule chose qui change tous les jours dans Keo a déjà son widget,
  « Ce jour-là », qui le fait avec des photos.

**Ce qui reste, et c'est le seul :** la couverture de l'index. Une bibliothèque de quinze ans
bouge de fractions de pour-cent par mois ; l'index, lui, avance de milliers de fichiers entre
deux coups d'œil, et son avancée demande quelque chose — ouvrir Keo et le laisser tourner.
C'est aussi le seul chiffre de l'app qui a une **fin** : le jour où tout est lu, la
complication le dit et le propriétaire la retire. Un widget de totaux n'a jamais eu ce
moment-là, parce qu'il n'a jamais eu de travail.

**Écran verrouillé seulement**, deux familles : `accessoryCircular` et `accessoryRectangular`.
Trois raisons, toutes assumées :

1. **C'est de la machinerie.** « La machinerie visible partout est la maladie qui fait
   qu'Immich ressemble à une console d'administration » — c'est l'argument qui a sorti
   l'indexation du menu de tri de chaque dossier. Une tuile d'indexation sur l'écran
   d'accueil, à côté de « Ce jour-là », referait exactement cette erreur. Une complication
   d'écran verrouillé est le seul emplacement du système où un voyant d'état est le contenu
   attendu.
2. **`systemSmall` et au-delà n'ont rien à mettre dans leurs pixels.** Deux lignes de texte
   dans 158 × 158 pt, c'est 80 % de vide — qu'il faudrait meubler avec un chiffre de vanité.
3. **`accessoryInline` est refusé** : une seule chaîne tronquée à côté de l'horloge, sans
   place pour le mot qui rend le nombre honnête. « 12 400 » sans « pas encore lus » ne veut
   rien dire.

**Ce qu'il dit**, dans les mots que la carte Bibliothèque emploie déjà, et jamais fusionnés :

| État | Titre | Détail |
|---|---|---|
| Rien d'indexé | « Index vide » | « Ouvre Keo pour le construire » |
| Marche en cours | « 3 812 dossiers sur 4 799 » | « 12 400 fichiers pas encore lus » |
| Dossiers finis, lecture non | « 12 400 fichiers pas encore lus » | « Tous les dossiers sont parcourus » |
| Terminé | « Bibliothèque à jour » | « 312 fichiers sans date » |

**« Pas encore lus » et « sans date » ne se croisent jamais**, et ce n'est pas une question de
place : le second n'est même pas *connaissable* tant que la marche n'est pas finie. L'ordre
des branches de `Coverage.lines` est donc la règle d'honnêteté elle-même, ce qui est la raison
pour laquelle ces phrases vivent dans `WidgetManifest.swift` plutôt que dans la vue —
`Tests/widget.swift` les tient.

**La barre est la moitié la moins avancée.** Deux fractions indépendantes : les dossiers
parcourus, et les fichiers lus. Une barre pleine sur les dossiers pendant que des fichiers
restent à lire promettrait une fin qui n'a pas eu lieu ; dans l'autre sens, des fichiers tous
lus ne disent rien des dossiers jamais listés. Le minimum des deux n'atteint 1 que lorsque les
deux y sont. Le pourcentage est **arrondi vers le bas** : « 100 % » affiché alors qu'il reste
deux fichiers à lire est le seul chiffre que ce widget existe pour ne pas imprimer. Et il peut
**reculer**, parce que `knownFolders` grossit au fur et à mesure que la marche découvre des
dossiers — c'est vrai, et l'écran de statistiques dit déjà la même chose en toutes lettres.

**L'appui ouvre les statistiques**, pas l'indexation. Un widget porte un nombre, jamais la
réserve qui le rend honnête ; son appui atterrit donc là où ces réserves sont imprimées — et
le bandeau de couverture, en haut de cet écran, porte justement le bouton « Continuer
l'indexation… ». C'est la destination `keo://stats`, nouvelle, parsée par `DeepLink` et
présentée en feuille par-dessus l'onglet courant : les statistiques sont le même écran quel
que soit l'onglet ouvert, et les empiler sous la pile en cours les enterrerait.

**Ce n'est pas une barre de progression en temps réel, et ça ne prétend pas l'être.**
`Indexer` s'arrête sur `didEnterBackgroundNotification` : l'index n'avance que pendant que
l'app est ouverte. Le widget répond « où j'en étais hier soir », pas « où j'en suis à la
seconde ». C'est exactement la question que « j'en suis où ? » pose.

Conséquence côté app : la couverture est écrite **avant** les deux garde-fous de
`WidgetRenderer.refresh` — le `guard !indexing` et l'étranglement horaire. Aucun des deux ne
s'applique à cinq scalaires lus dans SQLite local : ni box, ni second lecteur, ni vignette. Le
`guard !indexing`, surtout, gèlerait la couverture pendant toute la session qu'elle décrit.
L'écriture est sautée quand rien n'a bougé, parce qu'un rechargement fait rendre à l'extension
toute sa timeline et le faire pour réafficher le même nombre est du travail pour rien. Et le
champ `stamped` est **conservé** lors de cette écriture partielle, jamais rafraîchi : c'est lui
qui dit à « Ce jour-là » que ses souvenirs sont d'aujourd'hui.

**Mémoire** : aucune photo, donc rien à décoder et rien à retenir dans l'archive. Une entrée,
cinq entiers — de l'ordre du kilo-octet contre les trente mégaoctets de l'extension. C'est la
raison pour laquelle la discussion de la section suivante ne le concerne pas.

### Longueur de la timeline : une décision de mémoire

La timeline fait **4 entrées espacées de 6 h** : un rechargement de fond par jour, pour un
budget d'environ 40 à 70. `reloadAllTimelines()` depuis l'app au premier plan n'est pas
budgété du tout, et c'est lui qui fait réellement la fraîcheur — le nombre d'entrées n'y a
jamais rien changé.

Le nombre est contraint par la mémoire, pas par la fraîcheur. WidgetKit rend et archive
**toutes** les entrées d'une timeline en une passe, dans l'extension, et chaque entrée
archivée retient la photo que sa vue a décodée. Couvrir un grand widget coûte environ 5 Mo de
pixels quelle que soit la découpe. Les 48 entrées d'une demi-heure demandaient donc bien plus
de cent mégaoctets à une extension qui en a trente : elle était tuée avant d'avoir rien
dessiné — d'où un widget **noir et vide, sans même le texte de repli**, en moyen et en grand,
alors que le petit (un quart des pixels) passait. Quatre entrées ramènent le pire cas à 19 Mo.

Ce n'était **pas** un problème de disposition. `scaledToFill()` rend bien une taille plus
grande que la proposition, et le `.clipped()` qui suit découpe contre cette taille-là, donc
ne sert à rien — mais à la racine d'un widget l'hôte centre et recadre le débordement de
toute façon : rendues, les trois tailles étaient couvertes à **100 %**, aucun pixel noir.

Le `Color.clear.overlay { … }` que `Photo` utilise reste la bonne forme, pour une autre
raison : **dans une pile**, une cellule qui déborde est mesurée à sa largeur débordée et prend
la place de ses voisines. Un bandeau de trois cellules rendait **15 / 70 / 15** au lieu de
33 / 33 / 33. C'est ce qui aurait cassé la mosaïque et les tuiles de raccourcis.

Chaque décodage est dimensionné à **sa cellule**, pas au widget : la vedette de la mosaïque
tire 1092 px de côté long (3,6 Mo en 4:3), les trois cellules du bandeau 0,4 Mo chacune.

### Où atterrit un appui

Un appui sur le widget ouvrait Keo à la racine, ce qui est l'autre moitié du « pas très
pratique à l'usage ». Les URL viennent de `WidgetManifest.link(folder:)` et `link(day:)`,
et la façon de les poser n'est pas la même partout :

- **widget de dossier** et **Ce jour-là** : `widgetURL(_:)`, une destination pour tout le
  widget, puisqu'il n'en montre qu'un ;
- **raccourcis** : un `Link(destination:)` **par tuile**. `widgetURL` ne sait poser qu'une
  destination globale, et toutes les tuiles ouvriraient le même dossier — l'erreur qui ne se
  voit qu'en appuyant sur la deuxième ;
- **Index Keo** : `widgetURL(_:)` vers `keo://stats`, la seule destination sans paramètre.

### Récupérer le conteneur partagé depuis l'appareil

Le conteneur de groupe n'est **pas** dans celui de l'app : il a son propre domaine.

```sh
xcrun devicectl device info files --device <UDID> \
  --domain-type appGroupDataContainer --domain-identifier group.com.oasutalab.keo \
  --username mobile
xcrun devicectl device copy from --device <UDID> \
  --domain-type appGroupDataContainer --domain-identifier group.com.oasutalab.keo \
  --username mobile --source Widget --destination /tmp/keo-widget
```

Y vérifier `widget.json` (nombre de dossiers, noms d'images) et la taille des JPEG. L'app
trace la même chose à chaque rendu, en build DEBUG :

```sh
grep -a "\[keo\] widget" /tmp/keo-console.log
```

### À vérifier à la main

Rien de tout ceci ne se simule : il faut l'appareil, un widget posé, et de la patience.

- **Écran verrouillé.** Poser le widget, verrouiller, attendre un rafraîchissement : la photo
  reste visible. Si elle devient noire, la classe de protection est repassée à `complete`.
- **Avant le premier déverrouillage après un redémarrage.** Redémarrer le téléphone et
  regarder l'écran d'accueil **sans** déverrouiller : le widget doit afficher un état vide
  propre, jamais une case cassée. C'est le seul moment où
  `completeUntilFirstUserAuthentication` refuse réellement les fichiers.
- **Mode avion.** Le widget doit continuer à tourner sur ses photos déjà rendues. S'il affiche
  quoi que ce soit qui ressemble à une erreur réseau, c'est qu'il a appris à parler au NAS et
  il faut l'en empêcher.
- **Dossier désépinglé sous le widget.** Épingler un dossier, le choisir dans le widget,
  rouvrir Keo et le désépingler, puis laisser l'app re-rendre : le widget doit annoncer « Ce
  dossier n'est plus épinglé » et surtout **pas** les photos d'un autre dossier.
- **Widget posé avant le premier lancement de Keo.** Sur une installation neuve, poser le
  widget sans jamais ouvrir l'app : « Ouvre Keo pour remplir le widget », pas un crash.
- **Rien d'épinglé.** Ouvrir Keo sans aucun raccourci : « Épingle un dossier dans Keo ».
- **Les trois tailles du widget de dossier.** Poser « Keo » en **petit**, **moyen** *et*
  **grand**. Les trois doivent montrer des photos et le nom du dossier. C'est la vérification
  qui compte : le symptôme corrigé était un widget noir et vide en moyen et en grand, sans
  même le texte de repli, pendant que le petit marchait. S'il revient, ce n'est pas la
  disposition — c'est la mémoire : chercher un jetsam de `KeoWidgetExtension` dans
  `Réglages → Confidentialité → Analyse` et raccourcir encore `WidgetStore.steps`.
- **La mosaïque avec peu de photos.** Épingler un dossier d'**une seule** photo, puis de deux,
  puis de trois, et regarder le grand : vedette seule, puis vedette plus une, plus deux. Ni
  case vide, ni photo répétée.
- **Les deux tailles des raccourcis.** Poser « Raccourcis Keo » en moyen (trois tuiles) et en
  grand (deux rangs de trois). Avec **moins de trois** dossiers épinglés, les tuiles doivent
  garder leur taille et non s'étirer.
- **Chaque tuile ouvre son dossier.** Avec au moins trois dossiers épinglés, appuyer sur la
  **deuxième** puis la **troisième** tuile : Keo doit ouvrir le dossier de la tuile touchée,
  pas celui de la première ni la racine. C'est précisément ce que `widgetURL` ne sait pas
  faire, donc c'est là que la régression se verrait.
- **Appui sur le widget de dossier.** Keo doit ouvrir sur le dossier affiché, pas à la racine.
- **Ligne de contexte.** Sur un dossier entièrement indexé, le moyen doit lire
  « 14 595 photos · 2009 – 2024 ». Sur un dossier **en cours** d'indexation, le compte doit
  **disparaître** — jamais « 0 photo », qui se lirait « ce dossier est vide ».
- **« Ce jour-là », les trois tailles.** Un jour qui a des photos : les trois tailles les
  montrent, chaque cellule avec son « il y a N ans », et l'appui ouvre la recherche sur ce
  jour. Vérifier qu'une photo de l'année en cours dit « cette année » et non « il y a 0 an ».
- **« Ce jour-là » un jour vide.** La plupart des jours : « Rien ce jour-là dans les années
  passées ». Un widget vide ou une case cassée serait un échec ; cette phrase est le
  comportement attendu.
- **« Ce jour-là » après minuit.** Laisser le téléphone passer minuit **sans** ouvrir Keo :
  le widget doit basculer sur « Ouvre Keo pour les photos d'aujourd'hui » et surtout pas
  continuer à montrer les photos d'hier sous la date d'hier. Rouvrir Keo : il se remplit.
- **Mode teinté.** Passer l'écran d'accueil en teinté : les photos restent en couleur. Si
  elles deviennent des silhouettes blanches, un `widgetAccentedRenderingMode(.fullColor)` a
  sauté — il y en a un, dans `Photo`.
- **Galerie de widgets.** Les **quatre** widgets doivent apparaître avec leurs descriptions,
  « Raccourcis Keo » **sans** la taille petite, et « Index Keo » **uniquement** dans la section
  écran verrouillé — s'il apparaît en petit, moyen ou grand, une famille a été ajoutée par
  erreur et la tuile de machinerie est de retour sur l'écran d'accueil.
- **« Index Keo », cercle.** Poser la complication circulaire sur l'écran verrouillé : un
  anneau rempli à la fraction, le pourcentage lisible au centre. Vérifier qu'il n'affiche
  **pas** « 100 % » tant que la carte Bibliothèque annonce encore des fichiers à lire — le
  pourcentage est arrondi vers le bas exprès, et c'est le seul mensonge possible ici.
- **« Index Keo », rectangle.** La complication rectangulaire doit tenir sur trois lignes sans
  troncature au milieu d'un mot : titre, barre, détail. Comparer les deux phrases avec la
  ligne « Indexation » de la carte Bibliothèque dans l'app : elles doivent raconter la même
  chose.
- **Les deux moitiés de « sans date » ne se croisent pas.** Sur un index **incomplet**, le
  widget ne doit jamais prononcer « sans date » — personne n'a encore regardé ces fichiers.
  Sur un index **terminé**, il ne doit plus prononcer « pas encore lus ». C'est la règle
  d'honnêteté de l'écran de statistiques, portée telle quelle sur l'écran verrouillé.
- **La barre pendant une vraie indexation.** Lancer l'indexation, laisser tourner, quitter
  l'app, regarder l'écran verrouillé : le chiffre doit avoir avancé par rapport à la veille.
  Il ne bougera **pas** pendant qu'on le regarde — `Indexer` s'arrête au passage en arrière-
  plan — et c'est le comportement attendu, pas un gel.
- **La barre peut reculer.** Sur une bibliothèque où la marche découvre encore des dossiers,
  le pourcentage peut descendre d'un coup d'œil à l'autre. C'est juste : le dénominateur,
  ce sont les dossiers que l'index **connaît**.
- **L'appui sur « Index Keo ».** Keo doit ouvrir les statistiques en feuille, quel que soit
  l'onglet affiché, avec le bandeau de couverture et son bouton « Continuer l'indexation… »
  en haut. Pas la racine du NAS, pas l'écran d'indexation nu.
- **Avant le premier lancement de Keo.** Poser « Index Keo » sur une installation neuve sans
  jamais ouvrir l'app : « Ouvre Keo », jamais « 0 % » ni une case cassée.
- **Index jamais commencé.** Associer la box sans lancer l'indexation : « Index vide · Ouvre
  Keo pour le construire ».
- **Mode avion.** Comme les trois autres : aucun message qui ressemble de près ou de loin à
  une erreur réseau. Le widget ne lit qu'un fichier.
- **Numéro de build.** Après installation, vérifier que l'app démarre : iOS refuse une app
  dont l'extension ne porte pas la version de l'hôte, et l'échec se produit à l'installation,
  jamais à la compilation.

## Timeline

Quand le tri est par date, la grille se regroupe et un rail apparaît à droite.

- **Trois niveaux de regroupement** — années, mois, jours — dans le menu « … ».
  Sur quinze ans de photos, la vue mois produit
  cent-quatre-vingts en-têtes ; la vue années en produit quinze. Les cellules rétrécissent en
  s'éloignant, pour voir la forme d'une année d'un coup d'œil.
- **En-têtes collants**, avec le compte de photos. Un dossier qui tient dans un seul mois se
  regroupe par jour : sinon le regroupement n'apprendrait rien.
- Les dates viennent de l'EXIF dès que le scan ci-dessus est passé.
- **Rail de densité.** Chaque période reçoit un plancher de 5 pt avant que le reste soit
  réparti au prorata : en proportions pures, un mois creux devenait un trait d'un pixel,
  invisible et impossible à viser au doigt. Les libellés d'année s'écartent des bords et ne
  s'affichent qu'espacés de 26 pt, sinon ils se chevauchaient. La hauteur de chaque segment est la part de photos de la période, donc
  la forme du rail *est* la distribution — un long segment, c'est un mois où tu as beaucoup
  photographié. Les changements d'année sont étiquetés, avec au moins 64 pt entre deux : sur quinze ans, elles
s'empilaient par-dessus la grille. Et sans trait de rattachement après le texte — « 2025 – » se
lisait comme une étiquette privée de sa valeur. On le glisse pour sauter directement.
- **Le rail ne prend que 16 pt au repos**, et s'élargit à 44 pt une fois le doigt parti en
  glissade. Il en occupait 44 en permanence : un tiers de la colonne de droite ne pouvait plus
  ouvrir une photo, le tapotement partait au rail. Et il faut maintenant parcourir 8 pt pour
  l'armer, sinon un simple tapotement comptait comme une glissade et téléportait la grille.
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

## Indexer sans être interrompu

La demande était « que l'indexation continue en arrière-plan ou en veille ». La recherche a
renversé la prémisse : **un passage complet dure un quart d'heure**, pas une nuit — 41 000
fichiers à 50-60 par seconde, plus les listings. Le problème n'a jamais été de tenir des
heures, mais de ne pas être coupé pendant quinze minutes.

Deux réponses, de la plus sûre à la plus récente :

- **L'écran reste éveillé** tant que l'écran Indexation est ouvert et qu'un passage tourne.
  Aucun entitlement, aucun mode d'arrière-plan, aucune ligne du cycle de vie touchée : l'app
  reste au premier plan, donc toutes les garanties existantes s'appliquent telles quelles.
  « Branche-le et laisse-le sur cet écran » est une réponse produit légitime.
- **`BGContinuedProcessingTask`** (iOS 26) : un passage lancé *au doigt* survit au passage en
  arrière-plan et au verrouillage, avec une jauge du système et un bouton d'annulation. C'est
  la réponse littérale à la demande, et elle n'existait pas avant iOS 26.

### La seule ligne touchée dans le cycle d'indexation

L'observateur d'arrière-plan saute son `halt()` **uniquement si une tâche continue a réellement
commencé** — pas si elle a été soumise. La nuance est tout : une requête qu'iOS aurait refusée
laisserait sinon le parcours courir vers la suspension, c'est-à-dire exactement la forme du bug
qui avait un jour fait balayer l'index.

Et rien n'ajoute un chemin de complétion. C'est le critère de relecture : un diff qui crée un
nouvel endroit où `walkCompleted` peut devenir vrai est faux. Une expiration passe par la même
pause que l'arrière-plan (`pauseKeepingResume`), donc `WalkOutcome.isComplete(cancelled: true)`
reste faux, aucun balayage n'a lieu et la reprise au prochain lancement fonctionne comme avant.

### Ce qui a été écarté

- **`URLSession` en configuration background** : conçue pour peu de gros transferts, pas pour
  41 000 lectures de 24 Ko. Les transferts hors processus sont différables et iOS pénalise les
  réveils fréquents — le débit effectif se compterait en jours. Et il faudrait réécrire le
  cycle de vie que `CLAUDE.md` interdit de toucher sur raisonnement, pour un gain (survivre au
  kill) que `resumeWanted` couvre déjà.
- **L'entitlement multicast** : inutile. Keo fait de l'HTTP unicast vers un nom d'hôte qui
  résout en IP publique — le trafic n'est même pas classé « réseau local » par iOS.
- **Une tâche nocturne `BGProcessingTask`** : possible plus tard, mais c'est un confort et non
  une promesse, iOS décidant seul s'il l'exécute. Son risque principal est nommé d'avance : un
  réveil à 3 h du matin ne doit **jamais** passer par `Store.reconnectIfPossible`, dont le
  chemin d'échec supprime le jeton du trousseau et dé-apparierait l'app en silence.

## Banc d'essai des lectures

`Indexer.parallel` a longtemps valu 3 par prudence, sans jamais avoir été vérifié. Le bon
nombre est une propriété de la box et du réseau, pas du code : il se mesure. `ReadBench`
(builds debug, bouton en bas de l'écran Indexation) lit les mêmes prefixes de 24 Ko que
l'indexeur, à plusieurs niveaux de parallélisme, et trace le débit sur la console.

Trois précautions, chacune apprise en lisant un résultat faux :

- **Une tranche de fichiers par niveau.** Rejouer les mêmes fichiers d'un niveau à l'autre
  mesure le cache de la box, et chaque niveau paraît rapide dans l'ordre où il est passé.
- **Fenêtre contiguë, à un décalage tiré au sort.** La première version gardait l'ordre de la
  liste depuis le début, donc relancer la mesure retombait sur exactement les mêmes photos —
  le second passage a donné 243 f/s au lieu de 52, avec une courbe qui ne fait plus que
  monter. C'était le cache, pas la box.
- **Contiguë, et pas un mélange de tout le dossier.** La correction suivante mélangeait le
  pool : tous les niveaux sont alors tombés à 30 f/s quelle que soit la concurrence. Des
  lectures éparpillées sur huit mille photos sont dominées par les déplacements de tête du
  disque de la box, ce qui n'est pas la charge réelle — l'indexeur lit un dossier dans l'ordre
  de sa liste. Mesurer autre chose que la charge réelle donne un chiffre vrai et inutile.
- **Ordre des niveaux tiré au sort.** Sinon une dérive du réseau pendant la mesure flatte
  systématiquement les niveaux passés en premier.

Photos uniquement : la date d'une vidéo coûte un nombre variable de requêtes et mesurerait le
parseur. N'écrit rien, ni sur le NAS ni dans l'index.

Un seul passage ne suffit pas à conclure. La constante ne bouge que sur plusieurs passages
indépendants qui disent la même chose.

### Ce que quatre passages ont donné

| parallel | 10:28 | 14:05 | 14:07 | 14:09 | rang moyen |
|---|---|---|---|---|---|
| 1 | 36,3 | 42,5 | 22,5 | 21,2 | 7,0 |
| 2 | 52,5 | 43,7 | 40,4 | 30,6 | 5,75 |
| 3 | 48,8 | 60,0 | 91,6 | 31,7 | 4,5 |
| 4 | 63,2 | 64,6 | 64,6 | 50,4 | **2,5** |
| 6 | 56,5 | 71,2 | 153,9 | 40,5 | 2,75 |
| 8 | 70,7 | 59,4 | 164,4 | 42,2 | **2,5** |
| 12 | 67,4 | 63,4 | 60,6 | 42,5 | 3,0 |

Chaque niveau est classé **à l'intérieur de son propre passage**, pas comparé aux autres
passages : le débit absolu varie d'un facteur deux d'un passage à l'autre, et une moyenne des
débits bruts laisserait le passage de 14:07 décider pour les trois autres. Celui-là est à
jeter — 153 et 164 f/s à 30 Mb/s, c'est du cache : lancé deux minutes après le précédent, sa
fenêtre aléatoire a recouvert la sienne. C'est la limite résiduelle du banc, et elle se voit
au débit absolu.

Conclusion : `parallel = 3` est sous le plateau dans les quatre passages, battu à chaque fois
par au moins deux valeurs plus hautes. Retenu **4** plutôt que 8, qui a le même rang moyen :
l'écart est dans le bruit et le plus petit nombre laisse davantage de box aux vignettes,
seul coût que le banc ne mesure pas.

### Le banc reste

La mesure est faite et le chiffre est dans le code. Le banc sert quand même, parce que le bon
nombre est une propriété de la box et du réseau : il redeviendra faux le jour où la Freebox
change, où le disque du NAS change, ou où la taille du préfixe lu passe de 24 Ko à autre chose —
le coût par lecture décide de la concurrence optimale. Ce jour-là, ce qui manquerait n'est pas
le chiffre, c'est la méthode : il a fallu **trois résultats faux** avant d'en obtenir un honnête,
et ces trois leçons (une tranche de fichiers par niveau, fenêtre contiguë à décalage tiré au
sort, ordre des niveaux tiré au sort) sont dans le code du banc, pas dans le tableau. 118 lignes
qui ne compilent qu'en debug, contre deux heures et trois mesures fausses à refaire : il reste.

## Enregistrer dans Photos : un piège de Swift 6

`PHPhotoLibrary.performChanges` exécute son bloc sur sa propre file,
`com.apple.PHPhotoLibrary.transaction.high`. Écrit comme méthode d'instance de `Downloader`,
qui est `@MainActor`, le bloc héritait de cette isolation — et Swift 6 y insère alors un
contrôle qui **piège** dès que Photos l'appelle : `dispatch_assert_queue_fail`, à chaque
enregistrement.

Le symptôme trompait : le plantage arrivait juste après avoir accordé l'accès à la
photothèque, donc il avait l'air lié à l'autorisation. Il ne l'était pas — avant de
l'accorder, le code n'atteignait simplement jamais cette ligne.

La fonction est `nonisolated` et `static`, et ne reçoit que des valeurs `Sendable` : il n'y a
rien là-dedans que l'acteur ait à protéger. Trouvé en lisant le vrai rapport de plantage de
l'appareil, pas en raisonnant :

```sh
xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs | grep -i keo
xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs \
  --source "Keo-….ips" --destination /tmp/
```

## La barre d'actions du plein écran

Cinq cercles identiques, dans l'ordre où les fonctionnalités avaient été écrites. Le cœur —
l'action la plus fréquente, la seule avec un retour haptique — se retrouvait à l'extrémité la
plus difficile à atteindre pour un pouce, et le menu d'export portait une flèche *vers le bas*
alors que la moitié de son contenu est « Partager ».

**Le principe retenu : grouper par ce que l'action touche, puis ordonner par poids — la plus
lourde là où l'œil commence, la plus légère là où le pouce se repose.**

| | Action | Pourquoi là |
|---|---|---|
| 1 | Enregistrer / Partager | Déplace des octets hors du NAS : lent, délibéré, quitte l'app. Le plus loin du pouce au repos. |
| 2 | Note | La plus rare des trois écritures d'index, donc le créneau intérieur le moins bon. |
| 3 | Collection | Fréquence moyenne, position moyenne, collée au cœur parce que « mettre en favori / ranger » est un même geste mental. |
| 4 | Favori | La plus fréquente, un tap, réversible : la meilleure position. |
| — | Live | Détaché, dans sa propre bulle. Il ne modifie pas ce qui est enregistré mais ce qui est à l'écran — ce n'est pas la même famille. |

Keo a ici un avantage qu'aucune galerie n'a : **ni Modifier ni Supprimer**, puisque le NAS est
en lecture seule. Tout le problème du « destructif à l'extrémité » disparaît, et la barre peut
s'organiser uniquement par poids et fréquence.

### Ce qui change visuellement

Une seule capsule pour les quatre, au lieu de cinq fonds séparés — c'est l'idiome des îlots de
barre d'outils d'iOS 26, et c'est la vraie réponse à « pas très joli » : cinq objets flottants
plus un trou fantôme se lisent comme du désordre, une capsule et une bulle se lisent comme deux
objets. Verre liquide sur iOS 26, même géométrie en matériau en dessous.

**La teinte ne sert qu'à l'état**, jamais à l'identité : le cœur plein, la note présente, le
live en cours. Le glyphe de la note ne change plus (`text.quote` contre `text.quote.rtl` est
indistinguable à cette taille), et celui du live non plus — `livephoto.slash` veut dire
« effet Live désactivé » dans Photos, un autre verbe, et l'emprunter pour dire « arrêter »
enseignerait la mauvaise chose.

### Le créneau conditionnel ne décale plus rien

La bulle Live est une **superposition**, pas un frère de la capsule : une superposition est
positionnée, pas disposée contre ses voisins, donc son apparition ne peut pas déplacer la
capsule. La garantie passe d'une discipline qu'il faut penser — le créneau fantôme en
`Color.clear` qu'elle remplace — à une propriété de la géométrie.

`maxWidth: 560` est toute la stratégie iPad : inerte sur iPhone, et sur une tablette la grappe
reste un objet compact au centre plutôt que cinq glyphes éparpillés sur mille points.

### Deux bugs corrigés au passage

- **La barre entière disparaissait pendant un téléchargement**, donc le cœur avec. Seul le
  bouton d'export est désactivé maintenant : l'état se montre sur le contrôle qui l'a causé.
- **La barre de progression ne s'effaçait pas** avec le glissement de fermeture, ce qui laissait
  une bande opaque sous une photo déjà en train de rétrécir vers sa vignette.

## Transition de zoom grille ↔ photo

La photo sort de sa vignette et y retourne, au lieu d'un fondu au noir : `matchedTransitionSource`
sur chaque cellule, `navigationTransition(.zoom(sourceID:in:))` sur la visionneuse. API iOS 18,
rien à conditionner puisque c'est la cible du projet.

Trois détails sans lesquels ça ne marche qu'à moitié :

- **La cellule d'arrivée suit la pagination.** La visionneuse renvoie la photo courante, donc
  fermer sur la vingtième photo revient sur *celle-là*, pas sur celle qu'on avait touchée.
- **La grille s'y repositionne avant que la transition joue.** Un zoom vers une cellule sortie
  de l'écran n'a nulle part où atterrir.
- **La grille ne se re-trie pas sous la visionneuse.** Pendant l'indexation, les dates du
  dossier peuvent arriver alors qu'une photo est en plein écran. Les appliquer re-triait une
  grille que personne ne voyait, puis la fermeture recentrait sur la *nouvelle* position de la
  photo — le lecteur refaisait surface au milieu d'autres dates, sans retrouver les siennes.
  L'ancre `restore` du premier correctif ne couvrait pas ce chemin : elle jouait sous le
  voile, et le recentrage de fermeture passait par-dessus. Les dates sont donc mises en
  attente et appliquées à la fermeture, une fois la transition retombée, avec l'ancre
  habituelle — un re-tri derrière une photo travaille pour un public de personne.

Le geste de fermeture maison et la transition système veulent piloter la même animation : la
photo est rendue à son cadre naturel avant `dismiss()`, sinon le zoom démarre d'une image déjà
réduite par le glissement.

## Ce qui se réévalue pendant le scroll

Trois choses se cumulaient sur la grille de 14 600 éléments, et toutes les trois pendant le
scroll :

- Chaque en-tête épinglé publiait sa position par `PreferenceKey` à chaque frame, et
  `onPreferenceChange` écrivait un `@State` de `BrowserView` — donc réévaluait ses huit cents
  lignes de corps, par frame. Renvoyer une préférence dans l'état du parent est la façon
  canonique de défaire les conteneurs paresseux qui se trouvent en dessous.
- Chacune de ces réévaluations reconstruisait `Array(items.enumerated())` pour chaque section
  instanciée : un mois de 5 000 photos payait 5 000 allocations de tuples par frame, juste
  pour alimenter `ForEach`.
- Le geste de fermeture du plein écran cherchait la photo courante par balayage linéaire du
  tableau, à chaque frame du glissement.

La section active vit maintenant dans un `SectionCursor` observable que **seul le rail** lit :
le corps de la grille ne s'y abonne plus, donc seul le rail s'invalide. Les positions sont
pré-calculées une fois par chargement dans un dictionnaire, et la visionneuse en a un aussi.

## Le périmètre d'un sous-arbre était un balayage

`substr(path, 1, length(?1)) = ?1` enveloppe la colonne dans des appels de fonction, ce qui
rend le prédicat inutilisable par l'index sur `path` : **chacun des sept appelants balayait la
table entière**. Et `hasChildFolders` était appelé une fois par dossier du parcours — à
4 799 dossiers, quelques millions de visites de lignes par passage, pour une question dont la
réponse n'était lue que dans un cas sur deux.

Deux corrections :

- Le périmètre devient une **plage**, `path > ?1 AND path < ?2`, où `?2` est le préfixe dont
  le dernier octet est incrémenté. `/Photos/` devient `/Photos0` ; à la racine `/` devient
  `0`, ce qui tombe juste puisque `/` vaut 0x2F et `0` vaut 0x30. Les deux bornes cherchent
  directement dans l'index.
- `hasChildFolders` n'est plus interrogé que lorsque sa réponse peut changer quelque chose.

Le piège des plages par préfixe — `/A` et `/AB` sont voisins dans l'ordre des chaînes — est
épinglé dans `Tests/stats.swift`, à côté du cas de la racine.

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

## Couverture des tuiles de dossier

Une tuile de dossier montre une photo de l'intérieur plutôt qu'un rectangle teinté. Le choix
se fait **dans l'index SQLite**, sans rien demander à la box : les fichiers du sous-arbre y
sont déjà, avec leur genre et leur date de prise de vue.

La règle est `ORDER BY kind, capture DESC, path, name LIMIT 1`, lue dans cet ordre :

- **Une image avant une vidéo**, même si la vidéo est plus récente. Une couverture vidéo coûte
  une session AVFoundation ; une image coûte la sonde de 256 Ko que le pipeline fait de toute
  façon.
- **La capture la plus récente**, parce que la dernière chose qui s'est passée dans un dossier
  dit mieux ce qu'il contient qu'une photo tirée au hasard. SQLite classe `NULL` en dernier en
  `DESC` : une photo sans EXIF ne passe donc pas devant une photo datée.
- **Le chemin puis le nom** terminent le classement. Sans eux, deux photos de même date
  pourraient remonter dans un ordre différent d'une visite à l'autre et la tuile clignoterait.

La portée est le sous-arbre, comme les totaux : un parent qui ne contient que des
sous-dossiers emprunte la meilleure couverture du lot au lieu de rester vide.

Le coût : une requête préparée, réutilisée pour tous les dossiers visibles, lancée après le
premier rendu — jamais avant, la grille d'un dossier de 14 600 fichiers doit rester instantanée.
La vignette est demandée à la **taille de grille habituelle**, pas à une taille réduite : elle
partage alors son entrée de cache avec la cellule du dossier qu'on s'apprête à ouvrir, au lieu
de télécharger deux fois la même photo. Un dossier sans média indexé garde son glyphe.

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

## Statistiques

`StatsView`, dans le menu « … » de la racine. Tout est lu dans l'index local, jamais sur la
box : l'écran s'ouvre instantanément et fonctionne NAS éteint. Une seule requête d'actrice au
`.task`, le résultat est gardé tant que la feuille est ouverte — douze balayages de la table
`file` ne se refont pas à chaque rendu.

### L'honnêteté, et comment elle est tenue

Des statistiques sur un index à moitié construit mentent. Quatre mécanismes évitent ça, et
aucun n'est décoratif :

- **Le bandeau de couverture**, affiché dès que l'index est partiel : « Statistiques calculées
  sur les 3 812 dossiers indexés (sur 4 799 connus) · 12 400 fichiers jamais lus », avec le
  bouton qui mène à l'indexation. Il dit la population sur laquelle tout le reste est calculé.
  Le dénominateur, ce sont les dossiers que l'index **connaît** : un dossier jamais listé
  n'existe nulle part, et aucun chiffre ne peut prétendre le compter.
- **« Sans date » et « pas encore lues » ne fusionnent jamais.** Le premier est une vérité sur
  les fichiers — ils ne portent aucune date de prise de vue. Le second est une vérité sur
  l'index — personne n'a encore ouvert ces fichiers, ils en ont peut-être une. La colonne
  `file.read` existe exactement pour distinguer les deux ; les additionner fabriquerait un
  nombre qui ne décrit ni les uns ni les autres. Les deux lignes mènent d'ailleurs à des
  endroits différents : la liste des fichiers concernés pour la première, l'écran d'indexation
  pour la seconde.
- **Un sous-arbre incomplet annonce un plancher.** `folder.bytes` n'est écrit qu'à la fin d'un
  dossier lu de bout en bout. Un sous-arbre qui en contient d'autres, jamais pesés, affiche
  donc « ≥ 123 Go · 4 dossiers pas encore pesés » et pas un total ferme ; sa barre ne dessine
  que ce qui est réellement mesuré, parce qu'une barre inventerait une mesure.
- **Deux totaux qui ne se réconcilient pas, assumés.** La phrase sous « Poids » additionne
  `file.size`, c'est-à-dire tout ce qu'un listing a montré, lu ou non. Les barres additionnent
  `folder.bytes`, c'est-à-dire les seuls dossiers finis. Les deux sont vraies, elles ne tombent
  pas sur le même octet, et l'écran le dit plutôt que de maquiller l'écart.

« Doublons probables » porte sa réserve dans son titre : **même nom et même taille**, ce n'est
pas une empreinte. Deux photos différentes peuvent coïncider, et détecter autrement voudrait
dire télécharger toute la bibliothèque. Le pied de section le répète avant de parler
d'octets récupérables — et Keo, de toute façon, ne supprimera jamais rien sur la box.

Enfin : **chaque ligne mène quelque part.** Une année ouvre la grille de l'année, un jour
ouvre la journée, un sous-arbre ouvre le dossier, un groupe de doublons ouvre ses
emplacements réels, un gros fichier ouvre le dossier qui le contient. Un chiffre qu'on ne peut
pas aller vérifier est un chiffre qu'il ne faut pas croire.

Cette règle est aussi ce qui a décidé le contenu du widget « Index Keo » : un widget ne se
tape pas vers une grille, donc un seul chiffre de cet écran pouvait y monter. Voir
« Widget », section « Index Keo ».

### La racine n'est pas un dossier comme les autres

L'idiome de portée utilisé partout dans `IndexStore` était
`substr(path, 1, length(?1) + 1) = ?1 || '/'`. À la racine, `?1` vaut `/` et l'expression
cherche les chemins qui commencent par `//` : **aucun**. Vérifié sur la vraie base dans
`Tests/stats.swift`, pas déduit.

Ce n'était pas qu'un problème à venir pour les statistiques : `hasChildFolders("/")` répondait
déjà « pas d'enfants » et `listing("/")` ne rendait aucun sous-dossier depuis le cache. Le
préfixe est donc maintenant calculé en Swift (`Statistics.scopePrefix`, qui laisse `/`
tranquille et ajoute la barre ailleurs) et lié comme paramètre, pour les cinq requêtes de
sous-arbre à la fois — totaux de tuile, couvertures, listing, génération, poids.

### Ce qui n'est délibérément pas calculé

- **Le nombre total de fichiers en titre.** Il ne survit que comme dénominateur du bandeau :
  seul, il flatte sans rien apprendre.
- **La croissance du stockage dans le temps.** Elle reposerait sur `mtime`, qui sur un NAS est
  la date de **copie**. Toute l'app existe parce que cette date ment.
- **Appareil, objectif, ISO.** Le schéma n'a pas ces colonnes, et les ajouter voudrait dire
  relire chaque photo sur le réseau.
- **Carte des lieux, moyennes, séries, badges, camembert des types** — le camembert à trois
  parts en dit moins que la phrase qui le remplace.
- **Les plus vues** : rien ne compte les ouvertures, et l'ajouter serait un nouveau chemin
  d'écriture que personne n'a demandé.
- **Les doublons par empreinte** : il faudrait télécharger toute la bibliothèque.

### Zéro nouvel index

`file` est `WITHOUT ROWID` avec `PRIMARY KEY (folder_id, name, size)` : tout index secondaire
recopie la clé primaire entière, nom compris — soit à peu près une seconde copie de la table
sur le disque. Les requêtes de cet écran sont donc des balayages complets, assumés tant que
rien ne se mesure lent sur l'appareil. `file_by_identity(name, size)`, qui existait déjà, sert
au regroupement des doublons.

### Reste à vérifier à la main, sur l'appareil

- Le graphe « Chronologie » : la **tape sur une barre** ouvre bien l'année correspondante (le
  test ne couvre que la requête, pas le geste). Chaque année a de toute façon sa ligne
  tapable juste en dessous, qui elle est couverte.
- Le rendu du bandeau et des barres de poids sur un index réel, à moitié construit.

## Lire les traces de l'appareil

Le cycle de vie de l'indexation a coûté trois correctifs plausibles et faux. La quatrième
tentative est partie de ce que l'appareil raconte, et a trouvé la cause en une fois.

Les commandes sont dans `CLAUDE.md`, section « Appareil ».

`--console` relaie la sortie standard de l'app. `Indexer` trace, en build DEBUG uniquement,
chaque point de bascule : réception de l'arrière-plan, `halt`, retour au premier plan, relance,
et le verdict de fin de parcours avec tous ses compteurs.

C'est ce qui a montré, noir sur blanc, qu'une reprise visitait deux dossiers et se déclarait
terminée. **Ne pas modifier le cycle de vie de l'indexation sur la foi d'un raisonnement :
brancher la console d'abord.**

## Toucher, haptique et VoiceOver

Les cibles tactiles tiennent les 44 pt sans grossir à l'écran : la barre de sélection, les
pastilles d'indexation et le bouton « Retirer » du bandeau élargissent leur zone de contact,
pas leur dessin.

Trois retours haptiques, et seulement trois — le système possède déjà ceux du défilement et du
feuilletage, en ajouter par-dessus donnerait un appareil qui vibre en continu :

| Geste | Retour |
|---|---|
| Rail de timeline, à chaque période franchie | `.selection` |
| Cœur en plein écran | `.impact(.soft)` |
| Cellule ajoutée ou retirée de la sélection | `.selection` |

Le rail se déclenche sur la période active, pas sur la position du doigt : une glissade d'un
bout à l'autre rend un cran par mois traversé, pas cent vingt par seconde. Le cœur compte les
tapotements et non l'état du favori, sinon feuilleter d'une photo aimée vers une autre
vibrerait tout seul.

**À vérifier à la main** — rien de tout ça ne se simule, ni ne se teste depuis un Mac :

- Dossier daté, grille en mois : taper une photo de la colonne de droite l'ouvre, à ras du
  bord de l'écran. Puis glisser depuis ce même bord scrute toujours la timeline.
- Glisser le rail sur plusieurs années : un cran par période, aucun crépitement continu.
- Cœur en plein écran : une impulsion au tapotement, rien en feuilletant entre une photo
  aimée et une autre.
- Sélection : un cran par cellule, et « Tout » n'en produit qu'un seul.
- VoiceOver activé : balayer la grille annonce le nom du fichier et « Sélectionné » le cas
  échéant ; le rail est ignoré, les en-têtes de période servent de navigation ; en plein écran,
  les quatre boutons s'annoncent « Fermer », « Favori », « Ajouter à une collection »,
  « Enregistrer ou partager ».
- **Dates pendant le plein écran** : sur un gros dossier jamais indexé, lancer l'indexation,
  ouvrir une photo, attendre que le dossier finisse de passer (la pastille), puis fermer. La
  grille doit montrer la période qu'on avait quittée, la photo d'origine visible, puis se
  re-trier en restant sur cette période. Dans `trace.log` (build DEBUG), la séquence qui
  confirme le mécanisme : `dates held …` pendant le plein écran, puis `viewer dismissed …
  pending=N`, puis `dates applied … kept=true`. Ce qui le réfuterait : le bug reproduit **sans
  aucune** ligne `dates held` — une ligne `load … covered=true` désignerait alors un
  rechargement du listing derrière le voile, et `viewer dismissed … at=absent` une ancre
  perdue plutôt qu'un re-tri.

## Vérifier

La commande est dans `CLAUDE.md`, section « Avant de dire que c'est fait ».

La géométrie du rail vit dans `RailLayout`, sans SwiftUI, précisément pour être vérifiable.
`Tests/store.swift` exerce le **vrai SQLite** sur un répertoire temporaire : écriture, balayage
des fichiers disparus, survie des sous-arbres ignorés, adoption après renommage, et migration
depuis les anciens JSON. `Tests/covers.swift` y vérifie le classement des couvertures de
dossier, qui ne se voit autrement qu'à l'œil sur l'appareil. `Tests/stats.swift` fait de même
pour les statistiques : la portée à la racine, les sous-arbres pesés ou non, la séparation
« sans date » / « jamais lue », et le regroupement des doublons — tous des `GROUP BY` dont une
erreur ne se voit pas, puisqu'elle sort un chiffre plausible.

Couvre la garantie de lecture seule, l'enveloppe `{success, result}`, l'encodage des chemins,
la classification des médias, l'éviction LRU, l'arithmétique de progression, et toute la
partie pure de la synchronisation iCloud (`Tests/sync.swift`) — le moteur CloudKit lui-même ne
se teste qu'à la main, voir plus haut.

`Tests/exclusions.swift` épingle la règle d'exclusion dans les deux sens — ce qui doit sortir de
l'index, ce qui ne doit surtout pas en sortir, la casse — puis rejoue le nettoyage contre le vrai
SQLite et vérifie que favoris, notes, raccourcis et collections en sortent intacts.

`Tests/widget.swift` couvre le manifeste du widget et, contre le vrai SQLite, la sélection des
douze couvertures d'un dossier épinglé : tout le sous-arbre, les plus récentes d'abord, les
vidéos après les photos, les voisins au nom proche exclus. Il tient aussi la couverture de
l'index — la fraction qui suit la moitié la moins avancée, le pourcentage arrondi vers le bas,
et l'ordre des branches de `Coverage.lines`, qui est la règle « sans date » / « pas encore
lues » elle-même.

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
- **Une seule autorisation Freebox pour tous les appareils d'un même compte Apple**, puisque le
  jeton passe par le trousseau iCloud. Pas de révocation par appareil : retirer l'accès les
  retire tous.
- **Pas de téléchargement de dossier entier** — la sélection porte sur des fichiers.
- **Téléchargements en série** — une barre de progression lisible plutôt qu'un débit maximal.
- **Pas de cible de tests Xcode.** La logique vérifiable est pure et le script ci-dessus suffit ;
  à ajouter le jour où il faudra tester du code qui a besoin du simulateur.
