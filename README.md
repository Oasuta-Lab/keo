# Keo

Galerie photos/vidéos iOS native pour NAS, via WebDAV.

## Lancer

```sh
open Keo.xcodeproj     # ⌘R
```

Au premier lancement : adresse WebDAV du NAS, utilisateur, mot de passe.
Le mot de passe va dans le trousseau, le reste dans `UserDefaults`.

Activer WebDAV côté NAS :
- **Synology** — Panneau de configuration → Services de fichiers → WebDAV
- **QNAP** — Panneau de contrôle → Services réseau et fichiers → Web Server → WebDAV
- **TrueNAS / OMV** — service WebDAV sur le dataset voulu

## Ce qu'il y a dedans

| Fichier | Rôle |
|---|---|
| `Keo/WebDAV.swift` | Client `PROPFIND` + parsing multistatus (`URLSession`, zéro dépendance) |
| `Keo/Thumbs.swift` | Vignettes : range request 256 Ko → aperçu EXIF embarqué, cache disque + mémoire |
| `Keo/BrowserView.swift` | Grille `LazyVGrid`, dossiers, documents |
| `Keo/ViewerView.swift` | Plein écran : zoom `UIScrollView`, `AVPlayer`, QuickLook |

## Vérif

```sh
swiftc -swift-version 5 Keo/WebDAV.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
```
