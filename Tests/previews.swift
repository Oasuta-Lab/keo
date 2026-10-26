import Foundation

/// À qui la sonde de 256 Ko a le droit de servir de vignette.
///
/// Le piège vérifié ici a été mesuré, pas supposé : ImageIO fabrique une vignette à partir
/// d'un PNG tronqué sans le dire — bonne taille, bon rapport d'aspect, et 100 % de pixels
/// transparents. `accepts` ne regarde que la taille et le rapport, donc elle la prenait, la
/// cellule gardait un vide en cache, et le repli qui télécharge le fichier entier — celui qui
/// aurait marché — ne se déclenchait jamais.
func checkPreviewProbeTrust() {
    let probe = 256 << 10
    let big: Int64 = 20 << 20
    let small: Int64 = 100 << 10

    // --- les formats qui portent vraiment une vignette ---------------------------------
    for name in ["photo.jpg", "photo.JPEG", "sortie.heic", "scan.tiff",
                 "brut.dng", "canon.CR3", "nikon.nef", "sony.arw"] {
        assert(PreviewPolicy.trustsProbe(path: "/NAS/\(name)", size: big, probeBytes: probe),
               "\(name) embarque un aperçu avant ses pixels, la sonde suffit")
    }

    // --- ceux qui n'en portent pas : la sonde ne peut rien contenir d'utile -------------
    for name in ["capture.png", "animation.gif", "vieux.bmp", "moderne.webp"] {
        assert(!PreviewPolicy.trustsProbe(path: "/NAS/\(name)", size: big, probeBytes: probe),
               "\(name) n'a pas d'aperçu intégré : croire la sonde rendrait une image vide")
    }

    // --- sauf si le fichier tient entièrement dans la sonde -----------------------------
    assert(PreviewPolicy.trustsProbe(path: "/NAS/petite.png", size: small, probeBytes: probe),
           "un PNG plus petit que la sonde n'est pas tronqué : il n'y a rien à rater")
    assert(PreviewPolicy.trustsProbe(path: "/NAS/pile.png", size: Int64(probe), probeBytes: probe),
           "à la taille exacte de la sonde, le fichier est entier")
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/juste.png", size: Int64(probe) + 1,
                                      probeBytes: probe),
           "un octet de plus et le fichier est tronqué")

    // --- la casse de l'extension ne doit pas décider ------------------------------------
    assert(PreviewPolicy.trustsProbe(path: "/NAS/A/B.JPG", size: big, probeBytes: probe),
           "l'extension se compare en minuscules")
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/sans extension", size: big, probeBytes: probe),
           "sans extension, on ne parie pas")

    // --- un chemin qui contient « .jpg » ailleurs que dans l'extension ------------------
    assert(!PreviewPolicy.trustsProbe(path: "/NAS/exports.jpg/final.png", size: big,
                                      probeBytes: probe),
           "c'est l'extension du fichier qui compte, pas un dossier qui porte ce nom")

    // --- la clé de cache doit retirer les vignettes vides déjà écrites -----------------
    // Corriger le rendu ne suffisait pas : les vides étaient déjà sur le disque, et ce
    // dossier survit à une réinstallation. Changer de route change la clé.
    let plain = DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400)
    let full = DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400, variant: "full")
    assert(plain != full, "une route différente doit donner une clé différente")
    assert(plain == DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400, variant: ""),
           "une variante vide ne doit pas déplacer les clés déjà écrites")
    assert(DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 400)
           != DiskCache.key(for: "/NAS/x.png", size: big, maxPixel: 200),
           "la taille demandée fait toujours partie de la clé")

    print("ok — la sonde n'est crue que là où elle peut contenir un aperçu, "
        + "et la route choisie fait partie de la clé")
}
