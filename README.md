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
| `Keo/Sync/` | Miroir CloudKit de la personnalisation : identité des enregistrements, moteur |
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
`iCloud.fr.yieldstudio.keo`, `aps-environment`) et le mode background `remote-notification`.
Le build **simulateur** passe tel quel. Pour un appareil, une fois, dans Xcode avec le compte
de l'équipe ton équipe Apple :

1. Cible Keo → *Signing & Capabilities* → vérifier que les capacités **iCloud → CloudKit**
   (conteneur `iCloud.fr.yieldstudio.keo`) et **Push Notifications** apparaissent ; la
   signature automatique enregistre alors l'App ID et crée le conteneur.
2. Premier lancement en debug : le schéma (type `Personalisation`, champs chiffrés) se crée
   tout seul dans l'environnement **Development** au premier enregistrement.
3. Avant toute distribution : [CloudKit Console](https://icloud.developer.apple.com) →
   conteneur → *Deploy Schema Changes* vers **Production**. Sans ce clic, une build
   TestFlight/App Store ne peut rien écrire.

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

## Lire les traces de l'appareil

Le cycle de vie de l'indexation a coûté trois correctifs plausibles et faux. La quatrième
tentative est partie de ce que l'appareil raconte, et a trouvé la cause en une fois.

```sh
xcrun devicectl device install app --device <UDID> <chemin>/Keo.app
xcrun devicectl device process launch --device <UDID> \
  --terminate-existing --console fr.yieldstudio.keo > /tmp/keo-console.log 2>&1 &
grep -a "\[keo\]" /tmp/keo-console.log
```

`--console` relaie la sortie standard de l'app. `Indexer` trace, en build DEBUG uniquement,
chaque point de bascule : réception de l'arrière-plan, `halt`, retour au premier plan, relance,
et le verdict de fin de parcours avec tous ses compteurs.

C'est ce qui a montré, noir sur blanc, qu'une reprise visitait deux dossiers et se déclarait
terminée. **Ne pas modifier le cycle de vie de l'indexation sur la foi d'un raisonnement :
brancher la console d'abord.**

## Vérifier

```sh
rm -f /tmp/keocheck   # sinon un echec de compilation relance l'ancien binaire
swiftc -swift-version 6 -D DEBUG Keo/Freebox/Item.swift Keo/Freebox/Transport.swift \
  Keo/Freebox/FreeboxClient.swift Keo/Downloads/DownloadJob.swift \
  Keo/Freebox/MediaSection.swift Keo/Media/DiskCache.swift Keo/Media/PreviewPolicy.swift \
  Keo/Media/FolderStamp.swift Keo/Media/WalkOutcome.swift Keo/Media/IndexStore.swift \
  Keo/Media/VideoDate.swift Keo/UI/MediaDate.swift Keo/UI/RailLayout.swift \
  Keo/Sync/SyncModel.swift \
  Tests/main.swift Tests/store.swift Tests/favourites.swift Tests/videodatechecks.swift \
  Tests/sync.swift \
  -o /tmp/keocheck && /tmp/keocheck
```

La géométrie du rail vit dans `RailLayout`, sans SwiftUI, précisément pour être vérifiable.
`Tests/store.swift` exerce le **vrai SQLite** sur un répertoire temporaire : écriture, balayage
des fichiers disparus, survie des sous-arbres ignorés, adoption après renommage, et migration
depuis les anciens JSON.

Couvre la garantie de lecture seule, l'enveloppe `{success, result}`, l'encodage des chemins,
la classification des médias, l'éviction LRU, l'arithmétique de progression, et toute la
partie pure de la synchronisation iCloud (`Tests/sync.swift`) — le moteur CloudKit lui-même ne
se teste qu'à la main, voir plus haut.

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
