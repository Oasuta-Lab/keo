// Checks for the logic that can silently lie, plus a guard on the one rule that must never
// be broken: Keo never writes to the NAS.
//
// Run from the repo root:
//   rm -f /tmp/keocheck
//   swiftc -swift-version 6 Keo/Freebox/Item.swift Keo/Freebox/Transport.swift \
//     Keo/Freebox/FreeboxClient.swift Keo/Downloads/DownloadJob.swift \
//     Keo/Media/DiskCache.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
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

    let root = URL(fileURLWithPath: "Keo")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
        assertionFailure("sources introuvables — lance le check depuis la racine du dépôt")
        return
    }

    var sourceCount = 0
    var postSites: [String] = []

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

    assert(sourceCount > 5, "le scan n'a vu que \(sourceCount) fichiers, il a dû rater l'arbre")
    assert(postSites == ["Transport.swift"],
           "le seul POST autorisé est la poignée de main de login, trouvé dans : \(postSites)")
}

checkNothingWritesToTheNAS()

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
assert(contents.selectable.map(\.name) == ["x.jpg", "clip.mp4", "notes.pdf"],
       "l'ordre de sélection suit l'ordre affiché")
assert(FolderContents([]).isEmpty)

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

print("ok — lecture seule, envelope, chemins, classification, éviction, progression")
