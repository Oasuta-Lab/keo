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
| `Keo/Thumbs.swift` | Vignettes : range request 256 Ko → aperçu EXIF embarqué, cache disque + mémoire |
| `Keo/BrowserView.swift` | Grille `LazyVGrid`, dossiers, documents |
| `Keo/ViewerView.swift` | Plein écran : zoom `UIScrollView`, `AVPlayer`, QuickLook |

## Vérif

```sh
swiftc -swift-version 5 Keo/Freebox.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
```

## Limites connues

- **LAN uniquement.** L'accès distant (`kcux1ir3.fbxos.fr:41349`) marche, mais son certificat
  est signé par la CA Freebox, absente du magasin iOS — il faudra l'épingler.
- **Pas de vignettes côté serveur.** `fs/thumbnail` n'existe pas dans l'API : Keo lit l'aperçu
  JPEG embarqué via une requête Range de 256 Ko, sinon télécharge le fichier (plafond 40 Mo).
- **Pas de vignette vidéo** — icône film.
