import Foundation

enum FreeboxError: LocalizedError, Sendable {
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

    /// The session token expired or was never opened — worth exactly one retry.
    var isSessionProblem: Bool {
        if case .api(let code, _) = self {
            return code == "auth_required" || code == "invalid_session"
        }
        return false
    }
}

/// Every Freebox answer is wrapped in `{success, result}`; unwrap it in one place.
enum Envelope {
    static func unwrap<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.success == true else {
            throw FreeboxError.api(code: status.error_code ?? "unknown",
                                   message: status.msg ?? "Erreur Freebox.")
        }
        return try JSONDecoder().decode(Wrapper<T>.self, from: data).result
    }

    /// File endpoints answer a refusal with the same envelope instead of the bytes.
    static func failure(_ data: Data) -> FreeboxError {
        let status = try? JSONDecoder().decode(Status.self, from: data)
        return .api(code: status?.error_code ?? "auth_required",
                    message: status?.msg ?? "Accès refusé.")
    }

    private struct Status: Decodable {
        let success: Bool?
        let msg: String?
        let error_code: String?
    }

    private struct Wrapper<T: Decodable>: Decodable {
        let result: T
    }
}

// MARK: - Read-only transport

/// The only door to the NAS, and it only reads.
///
/// There is deliberately no way to express a write here: no HTTP method parameter, no request
/// body, no PUT/DELETE/MOVE, no `fs/mv`, `fs/rm` or `fs/mkdir`. A write against the user's NAS
/// would require adding a method to this type — which is the point. Everything above this
/// layer is structurally incapable of modifying, moving or deleting anything on the box.
///
/// The login handshake is the only thing that POSTs, and it lives in `LoginTransport` below,
/// out of reach of the data path.
struct ReadOnlyTransport: Sendable {
    static let authHeader = "X-Fbx-App-Auth"

    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Thumbnails take 6 at most; the extra slots keep the background date scan from
        // starving the grid.
        config.httpMaximumConnectionsPerHost = 9
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    func json<T: Decodable>(_ url: URL, token: String? = nil, as type: T.Type) async throws -> T {
        let (data, _) = try await session.data(for: request(url, token: token))
        return try Envelope.unwrap(data, as: type)
    }

    /// `prefix` caps the download to the first N bytes, for embedded-preview probes.
    func bytes(_ url: URL, token: String, prefix: Int? = nil) async throws -> Data {
        var call = request(url, token: token)
        if let prefix { call.setValue("bytes=0-\(prefix - 1)", forHTTPHeaderField: "Range") }

        let (data, response) = try await session.data(for: call)
        guard let http = response as? HTTPURLResponse else { throw FreeboxError.http(0) }
        if http.statusCode == 403 { throw Envelope.failure(data) }
        guard (200..<300).contains(http.statusCode) else { throw FreeboxError.http(http.statusCode) }
        return data
    }

    /// Streams to disk instead of holding the file in memory — the caller owns the result.
    func file(_ url: URL, token: String, named filename: String,
              onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (temp, response) = try await session.download(
            for: request(url, token: token), delegate: onProgress.map(DownloadProgress.init)
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FreeboxError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Keep the real filename: it is what the share sheet and Files show.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    private func request(_ url: URL, token: String?) -> URLRequest {
        var call = URLRequest(url: url)
        if let token { call.setValue(token, forHTTPHeaderField: Self.authHeader) }
        return call
    }
}

/// `URLSession.download(for:delegate:)` is the only async download that reports bytes written.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
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

// MARK: - Login

/// The handshake, and nothing else. Kept apart from `ReadOnlyTransport` so the data path has
/// no POST within reach.
struct LoginTransport: Sendable {
    let session: URLSession

    func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, _) = try await session.data(from: url)
        return try Envelope.unwrap(data, as: type)
    }

    func post<T: Decodable>(_ url: URL, body: [String: String], as type: T.Type) async throws -> T {
        var call = URLRequest(url: url)
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: call)
        return try Envelope.unwrap(data, as: type)
    }
}
