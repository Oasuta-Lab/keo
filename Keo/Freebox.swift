import CryptoKit
import Foundation

// MARK: - Model

struct Item: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let mimeType: String?

    var id: String { path }

    enum Kind { case folder, image, video, other }

    var kind: Kind {
        if isDirectory { return .folder }
        if let type = mimeType {
            if type.hasPrefix("image/") { return .image }
            if type.hasPrefix("video/") { return .video }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { return .image }
        if Self.videoExtensions.contains(ext) { return .video }
        return .other
    }

    static func == (a: Item, b: Item) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
    private static let videoExtensions: Set<String> =
        ["mp4", "mov", "m4v", "avi", "mkv", "hevc", "mpg", "mpeg", "3gp", "webm"]
}

enum FreeboxError: LocalizedError {
    case api(code: String, message: String)
    case http(Int)
    case denied
    case pairingTimedOut
    case noFileAccess

    var errorDescription: String? {
        switch self {
        case .api(_, let message): return message
        case .http(let code): return "Erreur réseau (\(code))."
        case .denied: return "Association refusée sur la Freebox."
        case .pairingTimedOut: return "Pas de réponse sur l'écran de la Freebox."
        case .noFileAccess:
            return "Keo n'a pas le droit d'accéder aux fichiers. Freebox OS → Paramètres → "
                 + "Gestion des accès → Applications → Keo → cocher « Accès aux fichiers »."
        }
    }

    /// The session token expired or was never opened — worth one retry.
    var isSessionProblem: Bool {
        if case .api(let code, _) = self {
            return code == "auth_required" || code == "invalid_session"
        }
        return false
    }
}

// MARK: - Discovery

struct FreeboxEndpoint: Equatable {
    /// e.g. http://mafreebox.freebox.fr/api/v16/
    let base: URL
    let boxName: String

    /// Asks the box which API major version it speaks, instead of hardcoding one.
    static func discover(host: String) async throws -> FreeboxEndpoint {
        struct Info: Decodable {
            let api_base_url: String
            let api_version: String
            let device_name: String?
        }
        guard let url = URL(string: "http://\(host)/api_version") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
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

    struct Request: Decodable {
        let app_token: String
        let track_id: Int
    }

    static func start(_ endpoint: FreeboxEndpoint, deviceName: String) async throws -> Request {
        let body = try JSONSerialization.data(withJSONObject: [
            "app_id": appID,
            "app_name": "Keo",
            "app_version": "0.1",
            "device_name": deviceName,
        ])
        return try await Transport.json(endpoint.base.appendingPathComponent("login/authorize/"),
                                        method: "POST", body: body, as: Request.self)
    }

    /// "pending" while the user hasn't touched the box yet.
    static func status(_ endpoint: FreeboxEndpoint, trackID: Int) async throws -> String {
        struct Progress: Decodable { let status: String }
        let url = endpoint.base.appendingPathComponent("login/authorize/\(trackID)")
        return try await Transport.json(url, as: Progress.self).status
    }
}

// MARK: - Client

actor FreeboxClient {
    static let rootPath = "/"

    nonisolated let endpoint: FreeboxEndpoint
    private let appToken: String
    private var sessionToken: String?
    private let session: URLSession

    init(endpoint: FreeboxEndpoint, appToken: String) {
        self.endpoint = endpoint
        self.appToken = appToken

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func list(_ path: String) async throws -> [Item] {
        struct Entry: Decodable {
            let path: String        // base64
            let name: String
            let type: String        // "dir" | "file"
            let mimetype: String?
            let size: Int64?
            let modification: TimeInterval?
            let hidden: Bool?
        }

        struct Listing: Decodable { let entries: [Entry] }

        let url = Self.apiURL(base: endpoint.base, suffix: "fs/ls/\(Self.encode(path))")
        let listing: Listing = try await authorized { request in
            try await Transport.json(request, as: Listing.self)
        } request: {
            URLRequest(url: url)
        }

        return listing.entries
            .filter { $0.hidden != true && !$0.name.hasPrefix(".") }
            .map { entry in
                Item(path: Self.decode(entry.path) ?? entry.path,
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
    }

    /// `firstBytes` limits the download to a prefix of the file (used for embedded thumbnails).
    func data(_ path: String, firstBytes: Int? = nil) async throws -> Data {
        try await authorized { request in
            try await Transport.bytes(request)
        } request: {
            var request = URLRequest(url: self.fileURL(path))
            if let firstBytes { request.setValue("bytes=0-\(firstBytes - 1)", forHTTPHeaderField: "Range") }
            return request
        }
    }

    /// Streams to a temp file, reporting progress. Used by QuickLook and by downloads.
    func download(_ path: String,
                  onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        do {
            return try await fetchFile(path, onProgress: onProgress)
        } catch FreeboxError.http(403) {
            sessionToken = nil
            return try await fetchFile(path, onProgress: onProgress)
        }
    }

    private func fetchFile(_ path: String,
                           onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        var request = URLRequest(url: fileURL(path))
        request.setValue(try await currentSession(), forHTTPHeaderField: "X-Fbx-App-Auth")

        let (temp, response) = try await session.download(
            for: request, delegate: onProgress.map(DownloadProgress.init)
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FreeboxError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Keep the real filename: it is what the share sheet and Files show.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// The single place AVFoundation gets a playable asset — player and thumbnailer both use it.
    func videoAsset(_ path: String) async throws -> AuthenticatedAsset {
        AuthenticatedAsset(url: fileURL(path),
                           token: try await currentSession(),
                           filename: (path as NSString).lastPathComponent)
    }

    /// AVPlayer and friends need the raw URL plus the session header.
    nonisolated func fileURL(_ path: String) -> URL {
        Self.apiURL(base: endpoint.base, suffix: "dl/\(Self.encode(path))")
    }

    /// `appendingPathComponent` percent-escapes what it is given, so an already-encoded
    /// base64 path comes out double-encoded and the box answers `invalid_request`.
    static func apiURL(base: URL, suffix: String) -> URL {
        URL(string: suffix, relativeTo: base)?.absoluteURL ?? base
    }

    func currentSession() async throws -> String {
        if let sessionToken { return sessionToken }
        return try await openSession()
    }

    // MARK: Session

    @discardableResult
    private func openSession() async throws -> String {
        struct Challenge: Decodable { let challenge: String }
        struct Opened: Decodable {
            let session_token: String
            let permissions: [String: Bool]
        }

        let challenge = try await Transport.json(
            endpoint.base.appendingPathComponent("login/"), as: Challenge.self
        ).challenge

        let signature = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(challenge.utf8), using: SymmetricKey(data: Data(appToken.utf8))
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "app_id": Pairing.appID,
            "password": signature.map { String(format: "%02x", $0) }.joined(),
        ])

        let opened = try await Transport.json(
            endpoint.base.appendingPathComponent("login/session/"),
            method: "POST", body: body, as: Opened.self
        )
        guard opened.permissions["explorer"] == true else { throw FreeboxError.noFileAccess }

        sessionToken = opened.session_token
        return opened.session_token
    }

    /// Runs a request with the session header, reopening the session once if it went stale.
    private func authorized<T>(_ work: (URLRequest) async throws -> T,
                               request build: () -> URLRequest) async throws -> T {
        var request = build()
        request.setValue(try await currentSession(), forHTTPHeaderField: "X-Fbx-App-Auth")
        do {
            return try await work(request)
        } catch let error as FreeboxError where error.isSessionProblem {
            sessionToken = nil
            var retry = build()
            retry.setValue(try await openSession(), forHTTPHeaderField: "X-Fbx-App-Auth")
            return try await work(retry)
        }
    }

    // MARK: Paths

    /// The API takes and returns paths as base64; percent-encoding keeps "/" and "+" out of the URL path.
    static func encode(_ path: String) -> String {
        let encoded = Data(path.utf8).base64EncodedString()
        return encoded.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? encoded
    }

    static func decode(_ base64: String) -> String? {
        Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// `URLSession.download(for:delegate:)` is the only async download that reports bytes.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

// MARK: - Transport

/// Every Freebox response is `{success, result}` — unwrap it in one place.
enum Transport {
    static func json<T: Decodable>(_ url: URL, method: String = "GET",
                                   body: Data? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await json(request, as: type)
    }

    static func json<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var request = request
        if request.httpBody != nil, request.httpMethod == nil { request.httpMethod = "POST" }

        let (data, _) = try await URLSession.shared.data(for: request)
        return try unwrap(data, as: type)
    }

    static func bytes(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FreeboxError.http(0) }
        // The file endpoints answer with a JSON error envelope instead of the bytes.
        if http.statusCode == 403 { throw try failure(data) }
        guard (200..<300).contains(http.statusCode) else { throw FreeboxError.http(http.statusCode) }
        return data
    }

    static func unwrap<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.success == true else {
            throw FreeboxError.api(code: status.error_code ?? "unknown",
                                   message: status.msg ?? "Erreur Freebox.")
        }
        return try JSONDecoder().decode(Wrapper<T>.self, from: data).result
    }

    private static func failure(_ data: Data) throws -> FreeboxError {
        let status = try? JSONDecoder().decode(Status.self, from: data)
        return .api(code: status?.error_code ?? "auth_required",
                    message: status?.msg ?? "Accès refusé.")
    }
}

private struct Status: Decodable {
    let success: Bool?
    let msg: String?
    let error_code: String?
}

private struct Wrapper<T: Decodable>: Decodable {
    let result: T
}
