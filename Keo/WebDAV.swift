import Foundation

// MARK: - Model

struct DAVItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let contentType: String?

    var id: URL { url }

    enum Kind { case folder, image, video, other }

    var kind: Kind {
        if isDirectory { return .folder }
        if let t = contentType {
            if t.hasPrefix("image/") { return .image }
            if t.hasPrefix("video/") { return .video }
        }
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { return .image }
        if Self.videoExtensions.contains(ext) { return .video }
        return .other
    }

    static func == (a: DAVItem, b: DAVItem) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
    private static let videoExtensions: Set<String> =
        ["mp4", "mov", "m4v", "avi", "mkv", "hevc", "mpg", "mpeg", "3gp", "webm"]
}

enum DAVError: LocalizedError {
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "Identifiants refusés par le serveur."
        case .http(404): return "Dossier introuvable."
        case .http(405): return "Le serveur ne parle pas WebDAV à cette adresse."
        case .http(let code): return "Erreur serveur (\(code))."
        case .badResponse: return "Réponse inattendue du serveur."
        }
    }
}

// MARK: - Client

actor DAVClient {
    nonisolated let root: URL
    nonisolated let authHeader: String
    private let session: URLSession

    init(root: URL, username: String, password: String) {
        self.root = root.hasDirectoryPath ? root : root.appendingPathComponent("")
        self.authHeader = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func list(_ url: URL) async throws -> [DAVItem] {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        let parsed = MultiStatusParser(base: url).parse(data)
        let selfPath = Self.normalize(url.path)
        return parsed
            .filter { Self.normalize($0.url.path) != selfPath }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// `bytes` limits the download to a prefix of the file (used for embedded thumbnails).
    func data(_ url: URL, firstBytes bytes: Int? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let bytes { request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range") }

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return data
    }

    /// Streams to a temp file — for documents handed to QuickLook.
    func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (temp, response) = try await session.download(for: request)
        try Self.validate(response)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DAVError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw DAVError.http(http.statusCode) }
    }

    private static func normalize(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getcontenttype/>
        <D:getlastmodified/>
      </D:prop>
    </D:propfind>
    """
}

// MARK: - Multistatus parsing

final class MultiStatusParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var items: [DAVItem] = []

    private var text = ""
    private var href: String?
    private var isCollection = false
    private var size: Int64 = 0
    private var modified: Date?
    private var contentType: String?

    init(base: URL) {
        self.base = base
    }

    func parse(_ data: Data) -> [DAVItem] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "response" {
            href = nil; isCollection = false; size = 0; modified = nil; contentType = nil
        }
        if name == "collection" { isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            if href == nil { href = value }
        case "getcontentlength":
            size = Int64(value) ?? 0
        case "getcontenttype":
            contentType = value.split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        case "getlastmodified":
            modified = Self.httpDate.date(from: value)
        case "response":
            appendItem()
        default:
            break
        }
    }

    private func appendItem() {
        guard let href, let url = URL(string: href, relativeTo: base)?.absoluteURL else { return }
        let raw = url.lastPathComponent
        let name = raw.removingPercentEncoding ?? raw
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        items.append(DAVItem(url: url, name: name, isDirectory: isCollection,
                             size: size, modified: modified, contentType: contentType))
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
