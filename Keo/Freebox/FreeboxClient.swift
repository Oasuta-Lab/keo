import CryptoKit
import Foundation

// MARK: - Discovery

struct FreeboxEndpoint: Sendable, Equatable {
    /// e.g. http://mafreebox.freebox.fr/api/v16/
    let base: URL
    let boxName: String

    /// Ask the box which API major version it speaks instead of hardcoding one.
    static func discover(host: String, using transport: LoginTransport) async throws -> FreeboxEndpoint {
        struct Info: Decodable {
            let api_base_url: String
            let api_version: String
            let device_name: String?
        }
        guard let url = URL(string: "http://\(host)/api_version") else { throw URLError(.badURL) }

        // /api_version is the one endpoint that is not wrapped in an envelope.
        let (data, response) = try await transport.session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FreeboxError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let info = try JSONDecoder().decode(Info.self, from: data)

        let major = info.api_version.split(separator: ".").first.map(String.init) ?? "16"
        guard let base = URL(string: "http://\(host)\(info.api_base_url)v\(major)/") else {
            throw URLError(.badURL)
        }
        return FreeboxEndpoint(base: base, boxName: info.device_name ?? "Freebox")
    }
}

// MARK: - Pairing

/// One-time handshake: the box prints a prompt on its front panel and the user presses ✓.
enum Pairing {
    static let appID = "fr.yieldstudio.keo"

    struct Request: Decodable, Sendable {
        let app_token: String
        let track_id: Int
    }

    static func start(_ endpoint: FreeboxEndpoint, deviceName: String,
                      using transport: LoginTransport) async throws -> Request {
        try await transport.post(
            FreeboxPath.url(base: endpoint.base, suffix: "login/authorize/"),
            body: ["app_id": appID, "app_name": "Keo", "app_version": "0.1",
                   "device_name": deviceName],
            as: Request.self
        )
    }

    /// "pending" until the user touches the box.
    static func status(_ endpoint: FreeboxEndpoint, trackID: Int,
                       using transport: LoginTransport) async throws -> String {
        struct Progress: Decodable { let status: String }
        return try await transport.get(
            FreeboxPath.url(base: endpoint.base, suffix: "login/authorize/\(trackID)"),
            as: Progress.self
        ).status
    }
}

// MARK: - Paths

enum FreeboxPath {
    /// The API takes and returns paths as base64; percent-encoding keeps "/" and "+" from
    /// splitting the URL into extra segments.
    static func encode(_ path: String) -> String {
        let encoded = Data(path.utf8).base64EncodedString()
        return encoded.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? encoded
    }

    static func decode(_ base64: String) -> String? {
        Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `appendingPathComponent` percent-escapes what it is given, so an already-encoded base64
    /// path comes out double-encoded and the box answers `invalid_request`.
    static func url(base: URL, suffix: String) -> URL {
        URL(string: suffix, relativeTo: base)?.absoluteURL ?? base
    }
}

/// Everything AVFoundation needs to build an authenticated asset, as a value it can carry
/// across isolation boundaries.
struct VideoSource: Sendable {
    let url: URL
    let token: String
    let filename: String
}

// MARK: - Client

actor FreeboxClient {
    static let rootPath = "/"

    nonisolated let endpoint: FreeboxEndpoint

    private let appToken: String
    private let read: ReadOnlyTransport
    private let login: LoginTransport

    private var sessionToken: String?
    /// Coalesces concurrent opens. Without it, a grid that fires fifty thumbnail requests at
    /// launch opens fifty sessions against the box.
    private var opening: Task<String, Error>?

    init(endpoint: FreeboxEndpoint, appToken: String) {
        self.endpoint = endpoint
        self.appToken = appToken

        let session = ReadOnlyTransport.makeSession()
        self.read = ReadOnlyTransport(session: session)
        self.login = LoginTransport(session: session)
    }

    // MARK: Reading

    /// Lists a folder page by page.
    ///
    /// A single request dies on a large folder: the box's own nginx returns 504 after exactly
    /// 15 seconds, measured on a 14 600 file directory, every time. Paginated it answers in
    /// under three seconds — and the first page lands in about 200 ms, which is what
    /// `onFirstPage` is for: the grid can paint almost immediately.
    func list(_ path: String, order: ItemOrder = .newest,
              onFirstPage: (@Sendable (FolderContents) -> Void)? = nil) async throws -> FolderContents {
        var all: [Item] = []
        var cursor: String?
        var page = 0

        var size = Self.pageSize

        repeat {
            let batch = try await withTimeoutRetry(path, cursor: cursor, size: &size)
            all.append(contentsOf: batch.items)
            cursor = batch.cursor
            page += 1

            if page == 1, let onFirstPage, batch.cursor != nil {
                onFirstPage(FolderContents(all, order: order))
            }
            // Backstop against a box that keeps handing out cursors.
            if page >= Self.pageLimit { break }
        } while cursor != nil

        return FolderContents(all, order: order)
    }

    /// 2 000 is where it flattens out: bigger pages are no faster and hold more in memory.
    private static let pageSize = 2_000
    private static let smallestPage = 250
    private static let pageLimit = 200

    /// The box times out on its own under load. Asking for less is what gets through, so each
    /// failure halves the page before trying again instead of giving up on the folder.
    private func withTimeoutRetry(_ path: String, cursor: String?,
                                  size: inout Int) async throws -> (items: [Item], cursor: String?) {
        while true {
            do {
                return try await listPage(path, cursor: cursor, limit: size)
            } catch let error as FreeboxError where error.isBoxOverloaded && size > Self.smallestPage {
                size = max(size / 2, Self.smallestPage)
            }
        }
    }

    private func listPage(_ path: String, cursor: String?,
                          limit: Int) async throws -> (items: [Item], cursor: String?) {
        struct Entry: Decodable {
            let path: String        // base64
            let name: String
            let type: String        // "dir" | "file"
            let mimetype: String?
            let size: Int64?
            let modification: TimeInterval?
            let hidden: Bool?
            let filecount: Int?
        }
        // fs/ls answers `result = {"entries": [...], "cursor": "..."}`, not a bare array.
        struct Listing: Decodable {
            let entries: [Entry]
            let cursor: String?
        }

        var suffix = "fs/ls/\(FreeboxPath.encode(path))?limit=\(limit)"
        if let cursor, let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            suffix += "&cursor=\(escaped)"
        }
        let url = FreeboxPath.url(base: endpoint.base, suffix: suffix)

        let listing = try await authorized { token in
            try await read.json(url, token: token, as: Listing.self)
        }

        let items = listing.entries
            .filter { $0.hidden != true && !$0.name.hasPrefix(".") }
            .map { entry in
                Item(path: FreeboxPath.decode(entry.path) ?? entry.path,
                     name: entry.name,
                     isDirectory: entry.type == "dir",
                     size: entry.size ?? 0,
                     modified: entry.modification.map { Date(timeIntervalSince1970: $0) },
                     mimeType: entry.mimetype,
                     childCount: entry.type == "dir" ? entry.filecount : nil)
            }

        // An empty page with a cursor would spin forever.
        return (items, listing.entries.isEmpty ? nil : listing.cursor)
    }

    func bytes(_ path: String, prefix: Int? = nil) async throws -> Data {
        try await authorized { token in
            try await read.bytes(fileURL(path), token: token, prefix: prefix)
        }
    }

    func bytes(_ path: String, range: Range<Int64>) async throws -> Data {
        try await authorized { token in
            try await read.bytes(fileURL(path), token: token, range: range)
        }
    }

    func download(_ path: String,
                  onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await authorized { token in
            try await read.file(fileURL(path), token: token,
                                named: (path as NSString).lastPathComponent,
                                onProgress: onProgress)
        }
    }

    func videoSource(_ path: String) async throws -> VideoSource {
        VideoSource(url: fileURL(path),
                    token: try await currentSession(),
                    filename: (path as NSString).lastPathComponent)
    }

    nonisolated func fileURL(_ path: String) -> URL {
        FreeboxPath.url(base: endpoint.base, suffix: "dl/\(FreeboxPath.encode(path))")
    }

    // MARK: Session

    func currentSession() async throws -> String {
        if let sessionToken { return sessionToken }
        return try await openSession()
    }

    /// Runs a read with the session header, reopening the session once if it went stale.
    private func authorized<T: Sendable>(_ work: (String) async throws -> T) async throws -> T {
        do {
            return try await work(try await currentSession())
        } catch let error as FreeboxError where error.isSessionProblem || error.isForbidden {
            sessionToken = nil
            return try await work(try await openSession())
        }
    }

    private func openSession() async throws -> String {
        if let opening { return try await opening.value }

        let task = Task { [appToken, login, endpoint] in
            struct Challenge: Decodable { let challenge: String }
            struct Opened: Decodable {
                let session_token: String
                let permissions: [String: Bool]
            }

            let challenge = try await login.get(
                FreeboxPath.url(base: endpoint.base, suffix: "login/"), as: Challenge.self
            ).challenge

            let signature = HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(challenge.utf8), using: SymmetricKey(data: Data(appToken.utf8))
            )
            let opened = try await login.post(
                FreeboxPath.url(base: endpoint.base, suffix: "login/session/"),
                body: ["app_id": Pairing.appID,
                       "password": signature.map { String(format: "%02x", $0) }.joined()],
                as: Opened.self
            )
            guard opened.permissions["explorer"] == true else { throw FreeboxError.noFileAccess }
            return opened.session_token
        }

        opening = task
        defer { opening = nil }

        let token = try await task.value
        sessionToken = token
        return token
    }
}

private extension FreeboxError {
    var isForbidden: Bool {
        if case .http(403) = self { return true }
        return false
    }

    /// The box gave up before the backend finished, rather than refusing the request.
    var isBoxOverloaded: Bool {
        if case .http(let code) = self { return code == 503 || code == 504 }
        return false
    }
}
