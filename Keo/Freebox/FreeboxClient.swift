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

    func list(_ path: String) async throws -> FolderContents {
        struct Entry: Decodable {
            let path: String        // base64
            let name: String
            let type: String        // "dir" | "file"
            let mimetype: String?
            let size: Int64?
            let modification: TimeInterval?
            let hidden: Bool?
        }
        // fs/ls answers `result = {"entries": [...]}`, not a bare array.
        struct Listing: Decodable { let entries: [Entry] }

        let url = FreeboxPath.url(base: endpoint.base, suffix: "fs/ls/\(FreeboxPath.encode(path))")
        let listing = try await authorized { token in
            try await read.json(url, token: token, as: Listing.self)
        }

        let items = listing.entries.lazy
            .filter { $0.hidden != true && !$0.name.hasPrefix(".") }
            .map { entry in
                Item(path: FreeboxPath.decode(entry.path) ?? entry.path,
                     name: entry.name,
                     isDirectory: entry.type == "dir",
                     size: entry.size ?? 0,
                     modified: entry.modification.map { Date(timeIntervalSince1970: $0) },
                     mimeType: entry.mimetype)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        return FolderContents(items)
    }

    func bytes(_ path: String, prefix: Int? = nil) async throws -> Data {
        try await authorized { token in
            try await read.bytes(fileURL(path), token: token, prefix: prefix)
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
}
