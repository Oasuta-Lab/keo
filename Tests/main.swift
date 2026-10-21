// Check for the one piece of real logic here: parsing a WebDAV multistatus body.
// Run: swiftc Keo/WebDAV.swift Tests/main.swift -o /tmp/keocheck && /tmp/keocheck
import Foundation

let xml = """
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/photos/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/photos/2024%20ete/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/photos/IMG_01.JPG</d:href>
    <d:propstat><d:prop>
      <d:resourcetype/>
      <d:getcontentlength>1234</d:getcontentlength>
      <d:getcontenttype>image/jpeg; charset=binary</d:getcontenttype>
      <d:getlastmodified>Tue, 21 Oct 2025 10:00:00 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>http://nas.local/photos/clip.MOV</d:href>
    <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>99</d:getcontentlength></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/photos/.DS_Store</d:href>
    <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
  </d:response>
</d:multistatus>
"""

let base = URL(string: "http://nas.local/photos/")!
let items = MultiStatusParser(base: base).parse(Data(xml.utf8))

assert(items.count == 4, "dotfiles dropped, everything else kept — got \(items.count)")

assert(items[0].isDirectory && items[0].name == "photos")
assert(items[1].name == "2024 ete", "percent-decoded name — got \(items[1].name)")
assert(items[1].isDirectory)

let photo = items[2]
assert(photo.kind == .image && photo.size == 1234)
assert(photo.contentType == "image/jpeg", "content-type params stripped — got \(photo.contentType ?? "nil")")
assert(photo.modified != nil, "RFC 1123 date parsed")
assert(photo.url.absoluteString == "http://nas.local/photos/IMG_01.JPG")

let clip = items[3]
assert(clip.kind == .video, "falls back to the extension when the server omits the type")
assert(clip.url.absoluteString == "http://nas.local/photos/clip.MOV", "absolute hrefs survive")

print("ok — \(items.count) items parsed")
