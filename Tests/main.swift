// Checks the pieces that can silently lie: the {success, result} envelope, the base64 path
// round-trip, and media classification.
// Run: swiftc -swift-version 5 Keo/Freebox.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
import Foundation

// MARK: envelope — success

struct Entry: Decodable {
    let path: String
    let name: String
    let type: String
    let mimetype: String?
    let size: Int64?
    let modification: TimeInterval?
    let hidden: Bool?
}

let listing = """
{"success":true,"result":[
  {"path":"L0Rpc3F1ZSBkdXIvUGhvdG9z","name":"Photos","type":"dir","mimetype":"inode/directory","size":4096,"modification":1740000000,"hidden":false},
  {"path":"L0Rpc3F1ZSBkdXIvYW/DqQ==","name":"aoé.jpg","type":"file","mimetype":"image/jpeg","size":1234,"modification":1740000001,"hidden":false}
]}
"""

let entries = try Transport.unwrap(Data(listing.utf8), as: [Entry].self)
assert(entries.count == 2)
assert(entries[0].type == "dir")
assert(entries[1].size == 1234)

// MARK: envelope — failure

let refused = """
{"success":false,"msg":"Vous devez vous connecter","error_code":"auth_required","result":{"challenge":"x"}}
"""
do {
    _ = try Transport.unwrap(Data(refused.utf8), as: [Entry].self)
    assertionFailure("un envelope success:false doit lever")
} catch let error as FreeboxError {
    assert(error.isSessionProblem, "auth_required doit déclencher une réouverture de session")
    assert(error.errorDescription == "Vous devez vous connecter")
} 

// MARK: base64 paths

for path in ["/", "/Disque dur", "/Disque dur/Photos/Noël 2024", "/Disque dur/aoé"] {
    let encoded = FreeboxClient.encode(path)
    assert(!encoded.contains("/"), "le base64 ne doit pas injecter de segment: \(encoded)")
    assert(!encoded.contains("+") && !encoded.contains("="), "tout est percent-encodé: \(encoded)")
    let raw = encoded.removingPercentEncoding!
    assert(FreeboxClient.decode(raw) == path, "aller-retour cassé pour \(path)")
}

// the API hands paths back base64-encoded too
assert(FreeboxClient.decode("L0Rpc3F1ZSBkdXIvYW/DqQ==") == "/Disque dur/aoé")

// MARK: classification

func item(_ path: String, dir: Bool = false, mime: String? = nil) -> Item {
    Item(path: path, name: (path as NSString).lastPathComponent, isDirectory: dir,
         size: 0, modified: nil, mimeType: mime)
}

assert(item("/Disque dur", dir: true, mime: "inode/directory").kind == .folder)
assert(item("/a/x.jpg", mime: "image/jpeg").kind == .image)
assert(item("/a/clip.MOV").kind == .video, "sans mimetype on retombe sur l'extension")
assert(item("/a/scan.CR3").kind == .image, "les RAW comptent comme des photos")
assert(item("/a/notes.pdf", mime: "application/pdf").kind == .other)

print("ok — envelope, chemins base64 et classification")
