# Keo

Galerie photos/vidéos iOS native pour Freebox, via l'API Freebox OS.

## Lancer

```sh
open Keo.xcodeproj     # ⌘R
```

Au premier lancement : « Associer à la Freebox », puis **appuyer sur ✓ sur la face
avant du Freebox Server**. Le jeton d'application va dans le trousseau iOS.

Si la navigation renvoie une erreur de droits : Freebox OS → Paramètres → Gestion des
accès → Applications → Keo → cocher « Accès aux fichiers ».

Pas de WebDAV sur la Freebox (vérifié : 404 sur `/dav`, `/webdav`, aucun en-tête `DAV:`),
donc tout passe par `fs/ls` et `dl` de l'API Freebox OS.

## Ce qu'il y a dedans

| Fichier | Rôle |
|---|---|
| `Keo/Freebox.swift` | API Freebox OS : association, session HMAC-SHA1, `fs/ls`, `dl` |
| `Keo/Thumbs.swift` | Vignettes : aperçu EXIF via range 256 Ko, image vidéo via `AVAssetImageGenerator`, cache disque + mémoire |
| `Keo/BrowserView.swift` | Grille `LazyVGrid`, dossiers, documents |
| `Keo/ViewerView.swift` | Plein écran : zoom `UIScrollView`, `AVPlayer`, QuickLook |
| `Keo/VideoAsset.swift` | `AVAssetResourceLoaderDelegate` qui porte `X-Fbx-App-Auth` jusqu'à AVFoundation |
| `Keo/Downloads.swift` | File d'attente, pellicule (`PHAssetCreationRequest`), feuille de partage |
| `Keo/DownloadJob.swift` | Arithmétique de progression d'un lot (isolée pour être testable) |

## Vérif

```sh
swiftc -swift-version 5 Keo/Freebox.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
```

## Télécharger

Menu « … » → **Sélectionner**, puis cocher les vignettes. Deux destinations :

- **Photos** — va dans la pellicule iOS. Réservé aux images et vidéos : le bouton se désactive
  si la sélection contient un PDF ou un `.procreate`.
- **Partager** — feuille de partage iOS, donc Fichiers, AirDrop, Mail… et tous les types.

La barre de progression affiche le fichier en cours, la position dans le lot et un bouton
Annuler. Même chose en plein écran, sur l'élément affiché.

## Limites connues

- **Pas de téléchargement de dossier entier** — la sélection porte sur des fichiers.
- **Téléchargements en série, pas en parallèle** — une barre de progression lisible plutôt
  qu'un débit maximal.

- **LAN uniquement.** L'accès distant (`kcux1ir3.fbxos.fr:41349`) marche, mais son certificat
  est signé par la CA Freebox, absente du magasin iOS — il faudra l'épingler.
- **Pas de vignettes côté serveur.** `fs/thumbnail` n'existe pas dans l'API : Keo lit l'aperçu
  JPEG embarqué via une requête Range de 256 Ko, sinon télécharge le fichier (plafond 40 Mo).
- **Vidéo : le transport passe par un resource loader.** `AVURLAssetHTTPHeaderFieldsKey` n'est pas
  documenté et iOS l'ignore, donc AVFoundation partait en 403 — vignette et lecture tombaient
  ensemble. `AuthenticatedAsset` refait les requêtes via `URLSession` avec le bon en-tête.
  Sur un MP4 dont l'atome `moov` est en fin de fichier, il faut deux allers-retours.

## Pièges de l'API Freebox, vérifiés sur la box

- `fs/ls` renvoie `result = {"entries": [...]}`, **pas** un tableau nu.
- Les chemins sont du base64 percent-encodé. `URL.appendingPathComponent` ré-encode le `%`
  (`Lw%3D%3D` → `Lw%253D%253D`) et la box répond `invalid_request` : construire l'URL
  avec `URL(string:relativeTo:)`.
- `dl/` honore `Range` (206 Partial Content), ce qui rend viable la lecture de l'aperçu
  embarqué : 256 Ko lus sur un JPEG de 2 Mo suffisent à sortir une vignette 400 px.
- `mafreebox.freebox.fr` résout vers une IP publique : ATS a besoin d'une exception de
  domaine, `NSAllowsLocalNetworking` ne suffit pas.
