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
        case .http(504), .http(503):
            return "La Freebox n'a pas répondu à temps. Elle est peut-être occupée — réessaie."
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
            // `invalid_session` is documented nowhere at Free; kept out of caution.
            return code == "auth_required" || code == "invalid_session"
        }
        return false
    }

    /// The box refuses the **application**, not the session: reopening will change nothing.
    ///
    /// `invalid_token` is the revoked token — the one a re-pairing elsewhere produces, since
    /// the Freebox only recognises one token per `app_id`. `pending_token` is a token that
    /// was issued but whose ✓ was never pressed. Both require a physical gesture on the box,
    /// or a fresher token from the keychain.
    ///
    /// `insufficient_rights` is deliberately not here: the token is fine there, it is the
    /// « Accès aux fichiers » permission that is missing, and re-pairing would change nothing.
    var isAuthorizationLost: Bool {
        if case .api(let code, _) = self {
            return code == "invalid_token" || code == "pending_token"
                || code == "new_apps_denied" || code == "apps_denied"
        }
        return false
    }

    /// The box's exact word, for the trace. The displayed message does not say which of the
    /// refusals this is — « Erreur d'authentification de l'application » can come out of more
    /// than one code, and the code is what decides whether the banner must appear.
    var apiCode: String? {
        if case .api(let code, _) = self { return code }
        return nil
    }

    /// The same refusal, seen from the handshake — and there, the list above is too short
    /// to serve as a guard.
    ///
    /// Opening a session asks for exactly one thing: that the box recognise the application
    /// token. If it refuses by naming it, **whatever the word**, that token is worth nothing
    /// any more; there is no session to reopen behind it and insisting can achieve nothing.
    /// A whitelist of codes here would be a bet on Free's vocabulary, when the question is
    /// already settled by where the error was born.
    ///
    /// `ratelimited` is the one exception, and it matters: it is temporary, lifts on its
    /// own, and mistaking it for a revocation would send someone to press ✓ — which would
    /// revoke the household's other devices over a minute of waiting.
    ///
    /// `noFileAccess` is not concerned: it is not an `.api`, and the token is fine there.
    var refusesTheApplication: Bool {
        if case .api(let code, _) = self { return code != "ratelimited" }
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
        let (data, response) = try await session.data(for: request(url, token: token))
        try Self.checkStatus(response, body: data)
        return try Envelope.unwrap(data, as: type)
    }

    /// Without this, a 504 hands its HTML error page to `JSONDecoder` and the user is told
    /// "the data couldn't be read because it isn't in the correct format".
    ///
    /// `body` is passed when we have it: the box explains its refusal in the response —
    /// `auth_required`, `insufficient_rights`, `invalid_token` — and without it, a 403 became
    /// « Erreur réseau (403) », which is wrong twice over: it is not the network, and it does
    /// not say which of the three failures this is. The byte requests already read this body;
    /// the JSON requests did not.
    static func checkStatus(_ response: URLResponse, body: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw FreeboxError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            if !body.isEmpty, let status = try? JSONSerialization.jsonObject(with: body),
               status is [String: Any] {
                throw Envelope.failure(body)
            }
            throw FreeboxError.http(http.statusCode)
        }
    }

    /// `prefix` caps the download to the first N bytes, for embedded-preview probes.
    func bytes(_ url: URL, token: String, prefix: Int? = nil) async throws -> Data {
        try await bytes(url, token: token, range: prefix.map { 0 ..< Int64($0) })
    }

    /// Arbitrary byte window, for the video date scanner — still a plain GET.
    func bytes(_ url: URL, token: String, range: Range<Int64>?) async throws -> Data {
        var call = request(url, token: token)
        if let range {
            call.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                          forHTTPHeaderField: "Range")
        }

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
        let (data, response) = try await session.data(from: url)
        try ReadOnlyTransport.checkStatus(response, body: data)
        return try Envelope.unwrap(data, as: type)
    }

    func post<T: Decodable>(_ url: URL, body: [String: String], as type: T.Type) async throws -> T {
        var call = URLRequest(url: url)
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: call)
        // This is where opening a session fails, and where the box names the cause.
        try ReadOnlyTransport.checkStatus(response, body: data)
        return try Envelope.unwrap(data, as: type)
    }
}
