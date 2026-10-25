// Checks for the logic that can silently lie, plus a guard on the one rule that must never
// be broken: Keo never writes to the NAS.
//
// Run from the repo root:
//   rm -f /tmp/keocheck
//   (la commande complète, tenue à jour, est dans README.md, section « Vérifier »)
import Foundation

// MARK: - The NAS is read-only

/// Structural guarantee, re-checked against the sources so it cannot rot: nothing outside the
/// login handshake may send a request that could alter the user's files.
/// Scans code, not prose: the doc comments below name the very routes they forbid.
func strippingComments(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let comment = line.range(of: "//") else { return line }
            return line[line.startIndex..<comment.lowerBound]
        }
        .joined(separator: "\n")
}

func checkNothingWritesToTheNAS() {
    let forbiddenVerbs = ["\"PUT\"", "\"DELETE\"", "\"PATCH\"", "\"MOVE\"", "\"MKCOL\"", "\"COPY\""]
    let forbiddenRoutes = ["fs/mv", "fs/rm", "fs/rename", "fs/mkdir", "fs/copy", "fs/delete",
                           "fs/archive", "fs/extract", "fs/chmod", "fs/cp"]

    // L'extension widget compte autant que l'app : un répertoire non parcouru rendrait la
    // garantie déclarative au lieu de structurelle.
    var sourceCount = 0
    var postSites: [String] = []

    for root in ["Keo", "KeoWidget"] {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
        else {
            assertionFailure("\(root) introuvable — lance le check depuis la racine du dépôt")
            return
        }

        for case let file as URL in walker where file.pathExtension == "swift" {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let text = strippingComments(raw)
            sourceCount += 1
            let name = file.lastPathComponent

            for verb in forbiddenVerbs {
                assert(!text.contains(verb), "\(name) emploie \(verb) : écriture possible sur le NAS")
            }
            for route in forbiddenRoutes {
                assert(!text.contains(route), "\(name) appelle \(route) : écriture possible sur le NAS")
            }
            if text.contains("httpMethod = \"POST\"") { postSites.append(name) }
        }
    }

    assert(sourceCount > 5, "le scan n'a vu que \(sourceCount) fichiers, il a dû rater l'arbre")
    assert(postSites == ["Transport.swift"],
           "le seul POST autorisé est la poignée de main de login, trouvé dans : \(postSites)")
}

checkNothingWritesToTheNAS()
checkDeepLinks()
checkHumanDates()

// MARK: - Le jeton d'application se synchronise

/// A source scan for the same reason as above: both ways of breaking a synchronizable item fail
/// by doing nothing at all — no error, no log, just a device that asks for the box button again.
/// A `…ThisDeviceOnly` class never leaves the device, and a query without `Synchronizable` is
/// blind to half the keychain, the attribute being part of the item's primary key.
func checkTheAppTokenCanSync() {
    let file = URL(fileURLWithPath: "Keo/App/Keychain.swift")
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
        assertionFailure("Keychain.swift introuvable — lance le check depuis la racine du dépôt")
        return
    }
    let source = strippingComments(raw)
    assert(!source.contains("ThisDeviceOnly"),
           "une classe ThisDeviceOnly ne se synchronise pas, et le refuse en silence")
    assert(source.contains("kSecAttrSynchronizableAny"),
           "lire ou supprimer sans Synchronizable: Any laisse passer un jeton de l'autre nature")
}

checkTheAppTokenCanSync()

// MARK: - Les deux copies du manifeste

/// L'extension porte sa propre copie de `WidgetManifest`, parce que partager le fichier
/// demanderait de le sortir du groupe synchronisé de l'app. Une copie qui dérive, c'est un
/// widget qui décode dans le vide sans rien dire : les deux sont donc comparées à l'octet.
func checkTheManifestCopiesMatch() {
    let app = "Keo/Media/WidgetManifest.swift"
    let widget = "KeoWidget/WidgetManifest.swift"
    guard let inApp = try? Data(contentsOf: URL(fileURLWithPath: app)),
          let inWidget = try? Data(contentsOf: URL(fileURLWithPath: widget)) else {
        assertionFailure("copies du manifeste introuvables — lance le check depuis la racine")
        return
    }
    assert(inApp == inWidget,
           "\(app) et \(widget) ont divergé : le widget décoderait dans le vide")
    assert(inApp.count > 200,
           "le manifeste fait \(inApp.count) octets, le scan a dû lire le mauvais fichier")
}

checkTheManifestCopiesMatch()

// MARK: - Envelope

struct Entry: Decodable {
    let path: String
    let name: String
    let type: String
    let mimetype: String?
    let size: Int64?
}
struct Listing: Decodable { let entries: [Entry] }

let listing = """
{"success":true,"result":{"entries":[
  {"path":"L05BUw==","name":"NAS","type":"dir","mimetype":"inode/directory","size":4096},
  {"path":"L0Rpc3F1ZSBkdXIvYW/DqQ==","name":"aoé.jpg","type":"file","mimetype":"image/jpeg","size":1234}
]}}
"""
let entries = try Envelope.unwrap(Data(listing.utf8), as: Listing.self).entries
assert(entries.count == 2, "fs/ls renvoie result = {entries: [...]}, pas un tableau nu")
assert(entries[1].size == 1234)

do {
    _ = try Envelope.unwrap(Data("""
    {"success":false,"msg":"Vous devez vous connecter","error_code":"auth_required","result":{}}
    """.utf8), as: Listing.self)
    assertionFailure("un envelope success:false doit lever")
} catch let error as FreeboxError {
    assert(error.isSessionProblem, "auth_required doit déclencher une réouverture de session")
    assert(error.errorDescription == "Vous devez vous connecter")
}

// MARK: - Chemins base64

for path in ["/", "/NAS", "/NAS/Photos/Noël 2024", "/NAS/aoé"] {
    let encoded = FreeboxPath.encode(path)
    assert(!encoded.contains("/"), "le base64 ne doit pas ajouter de segment : \(encoded)")
    assert(!encoded.contains("+") && !encoded.contains("="), "tout est percent-encodé : \(encoded)")
    assert(FreeboxPath.decode(encoded.removingPercentEncoding!) == path, "aller-retour cassé : \(path)")
}
assert(FreeboxPath.decode("L0Rpc3F1ZSBkdXIvYW/DqQ==") == "/Disque dur/aoé")

let base = URL(string: "http://mafreebox.freebox.fr/api/v16/")!
let url = FreeboxPath.url(base: base, suffix: "fs/ls/" + FreeboxPath.encode("/"))
assert(url.absoluteString == "http://mafreebox.freebox.fr/api/v16/fs/ls/Lw%3D%3D",
       "le base64 encodé doit passer tel quel — obtenu \(url.absoluteString)")
assert(!url.absoluteString.contains("%25"),
       "appendingPathComponent ré-encodait le %, la box répondait invalid_request")

// MARK: - Classification et découpage

func item(_ path: String, dir: Bool = false, mime: String? = nil) -> Item {
    Item(path: path, name: (path as NSString).lastPathComponent, isDirectory: dir,
         size: 0, modified: nil, mimeType: mime)
}

assert(item("/NAS", dir: true, mime: "inode/directory").kind == .folder)
assert(item("/a/x.jpg", mime: "image/jpeg").kind == .image)
assert(item("/a/clip.MOV").kind == .video, "sans mimetype on retombe sur l'extension")
assert(item("/a/scan.CR3").kind == .image, "les RAW comptent comme des photos")
assert(item("/a/notes.pdf", mime: "application/pdf").kind == .other)
assert(item("/a/x.jpg", mime: "image/jpeg").isMedia)
assert(!item("/a/notes.pdf", mime: "application/pdf").isMedia)

let contents = FolderContents([
    item("/NAS/Photos", dir: true), item("/a/x.jpg", mime: "image/jpeg"),
    item("/a/clip.mp4", mime: "video/mp4"), item("/a/notes.pdf", mime: "application/pdf"),
])
assert(contents.folders.count == 1)
assert(contents.media.count == 2, "images et vidéos vont dans la grille")
assert(contents.documents.count == 1)
assert(contents.selectableCount == 3, "tout sauf les dossiers est sélectionnable")
assert(contents.selectable.map(\.name) == ["clip.mp4", "x.jpg", "notes.pdf"],
       "l'ordre de sélection suit l'ordre affiché : médias triés puis documents, "
     + "et sans date le tri retombe sur le nom")
assert(FolderContents([]).isEmpty)

// MARK: - Regroupement en sections pour la timeline

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let fr = Locale(identifier: "fr_FR")

func onDay(_ iso: String, _ name: String) -> Item {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.dateFormat = "yyyy-MM-dd"
    return Item(path: "/a/\(name)", name: name, isDirectory: false, size: 0,
                modified: parser.date(from: iso), mimeType: "image/jpeg")
}

let acrossMonths = MediaGrouping.sections(from: [
    onDay("2024-08-20", "a.jpg"), onDay("2024-08-02", "b.jpg"),
    onDay("2024-07-15", "c.jpg"),
    onDay("2023-12-25", "d.jpg"),
], calendar: utc, locale: fr)

assert(acrossMonths.map(\.id) == ["2024-08", "2024-07", "2023-12"],
       "une section par mois, dans l'ordre reçu — \(acrossMonths.map(\.id))")
assert(acrossMonths.map { $0.items.count } == [2, 1, 1])
assert(acrossMonths.map(\.startIndex) == [0, 2, 3],
       "startIndex situe la section dans le tableau plat, pour le préchargement")
assert(acrossMonths[0].year == "2024" && acrossMonths[1].year == nil,
       "l'année ne s'affiche qu'au changement d'année")
assert(acrossMonths[2].year == "2023")
assert(acrossMonths[0].title.contains("2024"), "titre localisé — \(acrossMonths[0].title)")

// Un seul mois et beaucoup de photos : le mois seul ne regrouperait rien.
let holiday = (1...25).map { onDay(String(format: "2024-08-%02d", ($0 % 20) + 1), "p\($0).jpg") }
let byDay = MediaGrouping.sections(from: holiday, calendar: utc, locale: fr)
assert(byDay.count > 1, "un dossier tenant dans un mois se regroupe par jour")
assert(byDay[0].id.count == 10, "clé au jour près — \(byDay[0].id)")

// Peu de photos dans un seul mois : pas la peine de découper.
let few = MediaGrouping.sections(from: [onDay("2024-08-20", "a.jpg"), onDay("2024-08-21", "b.jpg")],
                                 calendar: utc, locale: fr)
assert(few.map(\.id) == ["2024-08"], "sous le seuil, on garde le mois")

// Les fichiers sans date restent navigables.
let undated = MediaGrouping.sections(from: [
    onDay("2024-08-20", "a.jpg"),
    Item(path: "/a/x.jpg", name: "x.jpg", isDirectory: false, size: 0,
         modified: nil, mimeType: "image/jpeg"),
], calendar: utc, locale: fr)
assert(undated.map(\.id) == ["2024-08", MediaGrouping.undatedID],
       "les sans-date forment leur propre section plutôt que d'être perdus")
assert(undated.last?.year == nil, "pas d'année pour les sans-date")

assert(MediaGrouping.sections(from: [], calendar: utc, locale: fr).isEmpty)

// MARK: - Reprise de l'indexation quand un dossier change

let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)

assert(FolderStamp.isUnchanged(recorded: indexedAt.timeIntervalSince1970, modified: indexedAt),
       "un dossier intact est ignoré, sans même être listé")

// Le cas qui compte : on ajoute des photos, la mtime du dossier bouge.
let afterAdding = Date(timeIntervalSince1970: 1_700_000_900)
assert(!FolderStamp.isUnchanged(recorded: indexedAt.timeIntervalSince1970, modified: afterAdding),
       "ajouter des photos doit forcer un nouveau passage sur le dossier")

assert(FolderStamp.isUnchanged(recorded: indexedAt.timeIntervalSince1970,
                               modified: indexedAt.addingTimeInterval(0.4)),
       "le bruit sous la seconde ne doit pas provoquer de relecture")
assert(!FolderStamp.isUnchanged(recorded: indexedAt.timeIntervalSince1970,
                                modified: indexedAt.addingTimeInterval(2)),
       "deux secondes d'écart, c'est un vrai changement")

assert(!FolderStamp.isUnchanged(recorded: nil, modified: indexedAt),
       "jamais indexé, donc jamais ignoré")
assert(!FolderStamp.isUnchanged(recorded: indexedAt.timeIntervalSince1970, modified: nil),
       "sans date de dossier, on ne peut rien garantir : on relit")
assert(FolderStamp.stamp(for: nil) == nil,
       "un dossier sans date n'est pas marqué comme terminé")

// MARK: - Un parcours interrompu ne doit jamais se croire complet

// Le cas qui a detruit l'index : l'app suspendue, chaque listing echoue, la file se vide
// toute seule et la boucle se termine sans annulation.
assert(!WalkOutcome.isComplete(cancelled: false, visited: 40, limit: 5_000,
                               listingFailures: 37, queueEmpty: true),
       "un parcours dont des dossiers étaient injoignables n'est pas complet")
assert(!WalkOutcome.maySweep(cancelled: false, visited: 40, limit: 5_000,
                             listingFailures: 1, queueEmpty: true),
       "et un seul échec suffit à interdire le balayage : il effacerait des dossiers bien vivants")

assert(WalkOutcome.isComplete(cancelled: false, visited: 40, limit: 5_000,
                              listingFailures: 0, queueEmpty: true),
       "un parcours sans échec et arrivé au bout est complet")

assert(!WalkOutcome.isComplete(cancelled: true, visited: 40, limit: 5_000,
                               listingFailures: 0, queueEmpty: true),
       "une annulation, c'est une pause, pas une fin")
assert(!WalkOutcome.isComplete(cancelled: false, visited: 5_000, limit: 5_000,
                               listingFailures: 0, queueEmpty: true),
       "le garde-fou anti-boucle atteint veut dire qu'on n'a pas tout vu")
assert(!WalkOutcome.isComplete(cancelled: false, visited: 10, limit: 5_000,
                               listingFailures: 0, queueEmpty: false),
       "il reste des dossiers à visiter : on ne conclut pas")

// MARK: - Géométrie du rail de la timeline

import CoreGraphics

let railHeight: CGFloat = 900

// Trois mois concentrent l'essentiel : en proportions pures les autres seraient des traits.
let busy = RailLayout.segments(counts: [2100, 1400, 1800, 30, 25, 15], height: railHeight)
assert(busy.count == 6)
assert(abs(busy[0].start) < 0.0001, "le premier segment part du haut")
let lastEnd = busy[5].start + busy[5].height
assert(abs(lastEnd - 1) < 0.001, "les segments couvrent exactement le rail — \(lastEnd)")
for segment in busy {
    assert(segment.height * railHeight >= RailLayout.minimumSegment - 0.001,
           "chaque période reste visible et cliquable — \(segment.height * railHeight) pt")
}
assert(busy[0].height > busy[3].height * 5, "la densité reste lisible malgré le plancher")

// Trop de périodes pour donner un plancher à chacune : on retombe sur les proportions.
let crowded = RailLayout.segments(counts: Array(repeating: 1, count: 400), height: 100)
assert(crowded.count == 400)
assert(abs(crowded.reduce(0) { $0 + $1.height } - 1) < 0.001,
       "même saturé, le rail couvre exactement sa hauteur")

assert(RailLayout.segments(counts: [], height: railHeight).isEmpty)
assert(RailLayout.segments(counts: [5], height: 0).isEmpty, "hauteur nulle, pas de division")

// Les années trop proches ne doivent pas se chevaucher.
let dense = RailLayout.segments(counts: [10, 10, 10, 10], height: railHeight)
let allYears = RailLayout.yearPositions(years: ["2026", "2025", "2024", "2023"],
                                        segments: dense, height: railHeight)
assert(allYears.count == 4, "bien espacées, toutes s'affichent")
for pair in zip(allYears, allYears.dropFirst()) {
    assert(pair.1.y - pair.0.y >= RailLayout.minimumYearGap, "espacement minimal respecté")
}

let squeezed = RailLayout.segments(counts: [1, 1, 1, 1], height: 60)
let fewYears = RailLayout.yearPositions(years: ["2026", "2025", "2024", "2023"],
                                        segments: squeezed, height: 60)
assert(fewYears.count < 4, "sur un rail court, on n'empile pas les étiquettes")

// Aucune étiquette ne sort de l'écran.
for label in allYears {
    assert(label.y >= RailLayout.edgeInset, "pas sous la barre d'état — \(label.y)")
    assert(label.y <= railHeight - RailLayout.edgeInset - RailLayout.labelHeight + 0.001,
           "pas coupée en bas — \(label.y)")
}

// Le glissé retombe sur la bonne période.
assert(RailLayout.index(at: 0, in: busy) == 0)
assert(RailLayout.index(at: 1, in: busy) == 5, "le bas du rail vise la dernière période")
assert(RailLayout.index(at: -5, in: busy) == 0, "au-dessus du rail, on reste sur la première")
assert(RailLayout.index(at: 0.5, in: []) == nil)

// MARK: - Dates de prise de vue appliquées après coup

// Le cas réel : tout a été copié sur le NAS le même jour, donc tous les mtimes sont identiques.
let copyDay = Date(timeIntervalSince1970: 1_700_000_000)
func copied(_ name: String) -> Item {
    Item(path: "/a/\(name)", name: name, isDirectory: false, size: 10,
         modified: copyDay, mimeType: "image/jpeg")
}

let bulk = FolderContents([copied("a.jpg"), copied("b.jpg"), copied("c.jpg")], order: .newest)
assert(bulk.media.allSatisfy { $0.timelineDate == copyDay },
       "sans EXIF, la timeline retombe sur la date de copie")

let discovered: [Item.ID: Date] = [
    "/a/a.jpg": Date(timeIntervalSince1970: 1_500_000_000),   // la plus ancienne
    "/a/b.jpg": Date(timeIntervalSince1970: 1_600_000_000),
    "/a/c.jpg": Date(timeIntervalSince1970: 1_650_000_000),   // la plus récente
]
let resolved = bulk.applying(discovered, order: .newest)
assert(resolved.media.map(\.name) == ["c.jpg", "b.jpg", "a.jpg"],
       "une fois les dates EXIF connues, l'ordre devient le vrai ordre chronologique")
assert(resolved.media[0].captureDate != nil && resolved.media[0].timelineDate != copyDay,
       "la date de prise de vue prime sur le mtime")
assert(resolved.media[0].modified == copyDay, "le mtime d'origine reste disponible")

assert(bulk.applying([:], order: .newest).media.map(\.name) == bulk.media.map(\.name),
       "sans rien à appliquer, la liste n'est pas remuée")

// Et le regroupement suit : un bloc unique devient une vraie timeline.
let beforeScan = MediaGrouping.sections(from: bulk.media, calendar: utc, locale: fr)
assert(beforeScan.count == 1, "mtimes identiques = une seule section, donc un rail inutile")

let afterScan = MediaGrouping.sections(from: resolved.media, calendar: utc, locale: fr)
assert(afterScan.count == 3, "après le scan, chaque photo retrouve son mois — \(afterScan.map(\.id))")
assert(afterScan.map(\.startIndex) == [0, 1, 2])

// MARK: - Niveaux de regroupement

let overYears = [
    onDay("2024-08-20", "a.jpg"), onDay("2024-02-02", "b.jpg"),
    onDay("2023-12-25", "c.jpg"), onDay("2023-01-05", "d.jpg"),
    onDay("2019-07-14", "e.jpg"),
]

let yearCut = MediaGrouping.sections(from: overYears, granularity: .year,
                                    calendar: utc, locale: fr)
assert(yearCut.map(\.id) == ["2024", "2023", "2019"],
       "en vue années, une section par année — \(yearCut.map(\.id))")
assert(yearCut[0].items.count == 2 && yearCut[2].items.count == 1)
assert(yearCut.map(\.year) == ["2024", "2023", "2019"],
       "chaque section porte son année, puisqu'elles changent toutes")
assert(yearCut[0].title.contains("2024"), "titre localisé — \(yearCut[0].title)")

let monthCut = MediaGrouping.sections(from: overYears, granularity: .month,
                                     calendar: utc, locale: fr)
assert(monthCut.count == 5, "en vue mois, cinq mois distincts — \(monthCut.count)")

let dayCut = MediaGrouping.sections(from: overYears, granularity: .day,
                                   calendar: utc, locale: fr)
assert(dayCut.count == 5)
assert(dayCut[0].id.count == 10, "clé au jour près — \(dayCut[0].id)")

// Les startIndex restent cohérents quel que soit le découpage.
for cut in [Granularity.year, .month, .day] {
    let cuts = MediaGrouping.sections(from: overYears, granularity: cut,
                                      calendar: utc, locale: fr)
    var expected = 0
    for section in cuts {
        assert(section.startIndex == expected,
               "startIndex suit l'ordre affiché en vue \(cut) — \(section.startIndex)")
        expected += section.items.count
    }
    assert(expected == overYears.count, "aucun élément perdu en vue \(cut)")
}

// Un dossier tenant dans un seul mois se découpe quand même par jour.
let holidayWeek = (1...25).map { onDay(String(format: "2024-08-%02d", ($0 % 20) + 1), "h\($0).jpg") }
let auto = MediaGrouping.sections(from: holidayWeek, granularity: .month,
                                  calendar: utc, locale: fr)
assert(auto.count > 1, "un mois unique se recoupe par jour, sinon la vue n'apprend rien")
let forcedYear = MediaGrouping.sections(from: holidayWeek, granularity: .year,
                                        calendar: utc, locale: fr)
assert(forcedYear.count == 1, "mais la vue années reste une vue années")

assert(Granularity.year.cellWidth < Granularity.month.cellWidth,
       "une vue plus large a des cellules plus petites")
assert(Granularity.month.cellWidth < Granularity.day.cellWidth)
assert(Granularity.allCases.count == 3)

// MARK: - Date affichée en plein écran

let shot = Date(timeIntervalSince1970: 1_000_000)
let copied = Date(timeIntervalSince1970: 2_000_000)

let fromExif = MediaDate(capture: shot, modification: copied)
assert(fromExif?.source == .capture, "la date de prise de vue prime sur le mtime")
assert(fromExif?.date == shot)
assert(fromExif?.text.hasPrefix("Modifié le") == false,
       "une vraie date de prise de vue s'affiche nue")

let fromMtime = MediaDate(capture: nil, modification: copied)
assert(fromMtime?.source == .modification)
assert(fromMtime?.text.hasPrefix("Modifié le") == true,
       "sans EXIF on annonce que c'est la date de modification, pas la prise de vue")

assert(MediaDate(capture: nil, modification: nil) == nil,
       "sans aucune date, on n'affiche rien plutôt qu'une date inventée")
assert(MediaDate(capture: shot, modification: nil)?.source == .capture)

// MARK: - Acceptation d'un aperçu embarqué

func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

// Le cas réel qui a motivé ça : un JPEG 6016×6016 dont la vignette EXIF fait 160×160.
assert(!PreviewPolicy.accepts(preview: size(160, 160), fullImage: size(6016, 6016), requested: 400),
       "une vignette de 160 px étirée dans une cellule de 400 px se voit")
assert(PreviewPolicy.accepts(preview: size(400, 300), fullImage: size(4000, 3000), requested: 400),
       "même ratio et taille suffisante : on garde")
assert(PreviewPolicy.accepts(preview: size(300, 225), fullImage: size(4000, 3000), requested: 400),
       "75% de la taille demandée reste acceptable")

// Mauvais cadrage : vignette 4:3 pour une photo 16:9.
assert(!PreviewPolicy.accepts(preview: size(400, 300), fullImage: size(3840, 2160), requested: 400),
       "un ratio différent veut dire recadrage ou bandes noires")
assert(PreviewPolicy.drift(size(400, 300), size(4000, 3000)) == 0)
assert(PreviewPolicy.drift(size(400, 300), size(3840, 2160)) > 0.2)

assert(PreviewPolicy.accepts(preview: size(400, 300), fullImage: nil, requested: 400),
       "sans dimensions déclarées, la taille seule décide")
assert(!PreviewPolicy.accepts(preview: size(0, 0), fullImage: nil, requested: 400),
       "une vignette vide n'est jamais acceptable")

// Orientation : les quarts de tour échangent largeur et hauteur.
assert(PreviewPolicy.oriented(size(4000, 3000), exifOrientation: 6) == size(3000, 4000),
       "orientation 6 = quart de tour, dimensions échangées")
assert(PreviewPolicy.oriented(size(4000, 3000), exifOrientation: 1) == size(4000, 3000))
assert(PreviewPolicy.oriented(size(4000, 3000), exifOrientation: nil) == size(4000, 3000))
assert(PreviewPolicy.accepts(preview: size(300, 400),
                             fullImage: PreviewPolicy.oriented(size(4000, 3000), exifOrientation: 6),
                             requested: 400),
       "une photo portrait ne doit pas être rejetée à cause de l'orientation")

// MARK: - Tri

func dated(_ name: String, _ day: Int?) -> Item {
    Item(path: "/a/\(name)", name: name, isDirectory: false, size: 0,
         modified: day.map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) },
         mimeType: "image/jpeg")
}

let shuffled = [dated("vieille.jpg", 10), dated("sans-date.jpg", nil),
                dated("recente.jpg", 30), dated("moyenne.jpg", 20)]

assert(shuffled.sorted(by: ItemOrder.newest.precedes).map(\.name)
    == ["recente.jpg", "moyenne.jpg", "vieille.jpg", "sans-date.jpg"],
       "plus récentes d'abord, les sans-date à la fin")

assert(shuffled.sorted(by: ItemOrder.oldest.precedes).map(\.name)
    == ["vieille.jpg", "moyenne.jpg", "recente.jpg", "sans-date.jpg"],
       "plus anciennes d'abord, les sans-date toujours à la fin")

assert(shuffled.sorted(by: ItemOrder.name.precedes).map(\.name)
    == ["moyenne.jpg", "recente.jpg", "sans-date.jpg", "vieille.jpg"])

assert([dated("b.jpg", 5), dated("a.jpg", 5)].sorted(by: ItemOrder.newest.precedes).map(\.name)
    == ["a.jpg", "b.jpg"], "à date égale, on départage par nom")

assert([dated("x.jpg", nil), dated("a.jpg", nil)].sorted(by: ItemOrder.newest.precedes).map(\.name)
    == ["a.jpg", "x.jpg"], "deux sans-date se départagent par nom")

let mixed = FolderContents([
    item("/NAS/Zèbre", dir: true), item("/NAS/Abeille", dir: true),
    dated("vieille.jpg", 10), dated("recente.jpg", 30),
], order: .newest)
assert(mixed.folders.map(\.name) == ["Abeille", "Zèbre"],
       "les dossiers restent alphabétiques, leur mtime ne veut rien dire")
assert(mixed.media.map(\.name) == ["recente.jpg", "vieille.jpg"])

let flipped = mixed.reordered(by: .oldest)
assert(flipped.media.map(\.name) == ["vieille.jpg", "recente.jpg"], "réordonner sans refetch")
assert(flipped.folders.map(\.name) == ["Abeille", "Zèbre"], "les dossiers ne bougent pas")

// MARK: - Éviction du cache disque

func entry(_ name: String, age: TimeInterval, size: Int64) -> DiskCache.Entry {
    DiskCache.Entry(url: URL(fileURLWithPath: "/tmp/\(name)"),
                    lastUsed: Date(timeIntervalSince1970: 1_000_000 - age), size: size)
}

let files = [entry("recent", age: 0, size: 100),
             entry("vieux", age: 500, size: 100),
             entry("ancien", age: 900, size: 100)]

assert(DiskCache.evictions(from: files, budget: 1000).isEmpty, "sous le budget, on ne jette rien")

let onePass = DiskCache.evictions(from: files, budget: 250)
assert(onePass.map(\.lastPathComponent) == ["ancien"],
       "on jette le moins récemment utilisé d'abord — \(onePass.map(\.lastPathComponent))")

let twoPass = DiskCache.evictions(from: files, budget: 100)
assert(twoPass.map(\.lastPathComponent) == ["ancien", "vieux"],
       "on continue jusqu'à repasser sous le budget — \(twoPass.map(\.lastPathComponent))")

assert(DiskCache.evictions(from: [], budget: 0).isEmpty, "un cache vide ne divise pas par zéro")
assert(DiskCache.key(for: "/a.jpg", size: 1, maxPixel: 400)
    != DiskCache.key(for: "/a.jpg", size: 1, maxPixel: 200),
       "la taille demandée fait partie de la clé")

// MARK: - Progression d'un lot

var job = DownloadJob(total: 4, completed: 0, currentName: "a.jpg", currentFraction: 0)
assert(job.fraction == 0 && job.position == 1)

job.currentFraction = 0.5
assert(job.fraction == 0.125, "le fichier en cours compte pour sa fraction — \(job.fraction)")

job.completed = 3
job.currentFraction = 1
assert(job.fraction == 1, "ne doit pas dépasser 1 — \(job.fraction)")
assert(job.position == 4, "la position ne dépasse pas le total")

assert(DownloadJob(total: 0, completed: 0, currentName: "", currentFraction: 0).fraction == 0,
       "un lot vide ne divise pas par zéro")

print("ok — lecture seule, envelope, chemins, classification, aperçus, dates EXIF, reprise, parcours, sections, zoom, rail, tri, éviction, progression")

try await checkIndexStore()
try await checkMigration()
try await checkFavourites()
try await checkSearch()
try await checkNotes()
try await checkLivePhotos()
try await checkVideoDate()
try await checkSync()
try await checkFolderCovers()
try await checkStatistics()
try await checkRootIsNotItsOwnChild()
try await checkFolderExclusion()

try await checkWidget()
