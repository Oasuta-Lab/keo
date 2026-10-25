import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation won't carry `X-Fbx-App-Auth` for us: `AVURLAssetHTTPHeaderFieldsKey` is
/// undocumented and ignored, which left both playback and video thumbnails on a 403. A resource
/// loader is the supported way to own the transport, so the asset fetches through `URLSession`
/// with the header the Freebox requires.
///
/// Keep this object alive for as long as the asset is used — `setDelegate` holds it weakly.
final class AuthenticatedAsset {
    let asset: AVURLAsset
    private let loader: Loader

    init(source: VideoSource) {
        var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        let tagged = components?.url ?? source.url

        loader = Loader(origin: source.url, token: source.token, filename: source.filename)
        asset = AVURLAsset(url: tagged)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    /// Anything AVFoundation doesn't handle itself, so requests reach the delegate.
    private static let scheme = "keo-fbx"
}

/// AVFoundation hands a loading request to exactly one delegate and does not touch it again
/// until we finish it, so carrying it into a task is safe — the compiler cannot see that
/// guarantee, hence the box.
private struct PendingRequest: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}

/// `@unchecked` for the same reason: the stored state is immutable apart from one
/// lock-protected dictionary.
private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.oasutalab.keo.assetloader")

    private let origin: URL
    private let token: String
    private let contentType: String?
    private let session = URLSession(configuration: .ephemeral)

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(origin: URL, token: String, filename: String) {
        self.origin = origin
        self.token = token
        self.contentType = UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        let pending = PendingRequest(request: request)
        let task = Task { [weak self] in
            await self?.serve(pending.request)
            self?.forget(key)
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        lock.withLock { tasks.removeValue(forKey: key) }?.cancel()
    }

    private func forget(_ key: ObjectIdentifier) {
        _ = lock.withLock { tasks.removeValue(forKey: key) }
    }

    /// The most AVFoundation gets from one request, so an open-ended ask cannot pull a
    /// multi-gigabyte file into memory. It simply comes back for the next window.
    private static let window: Int64 = 4 << 20

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        var call = URLRequest(url: origin)
        call.setValue(token, forHTTPHeaderField: ReadOnlyTransport.authHeader)

        // Every request gets a bounded range, including the one that asks for nothing.
        //
        // AVFoundation's *first* request carries no `dataRequest` at all — it only wants to
        // know the length, the type and whether ranges work. Sending that one without a
        // `Range` header downloaded the whole file into memory to answer "how big is it",
        // which on a GoPro clip of several gigabytes simply never came back and left a black
        // screen. Two bytes answer the question just as well.
        let start: Int64
        let length: Int64
        if let data = request.dataRequest {
            start = data.requestedOffset
            length = data.requestsAllDataToEndOfResource
                ? Self.window
                : min(Int64(data.requestedLength), Self.window)
        } else {
            start = 0
            length = 2
        }
        call.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")

        do {
            let (payload, response) = try await session.data(for: call)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                request.finishLoading(with: FreeboxError.http(code))
                return
            }

            if let information = request.contentInformationRequest {
                information.isByteRangeAccessSupported = true
                information.contentType = contentType
                // From `Content-Range`, never from how much came back: the payload is now a
                // window by design, and reporting its size as the file's would make
                // AVFoundation believe the video is four megabytes long.
                information.contentLength = Self.totalLength(response) ?? Int64(payload.count)
            }
            // Short answers are expected and fine: AVFoundation asks again from where this
            // one stopped. That is what makes the cap above safe.
            request.dataRequest?.respond(with: payload)
            request.finishLoading()
        } catch is CancellationError {
            // AVFoundation already dropped the request.
        } catch {
            request.finishLoading(with: error)
        }
    }

    /// `Content-Range: bytes 0-1/12345` — the part after the slash is the real file size.
    ///
    /// `expectedContentLength` is only a fallback, and a poor one now: on a ranged reply it
    /// describes the window, not the file. A server that answers a range without
    /// `Content-Range` would make the video look two bytes long, so `nil` is the honest
    /// answer there and AVFoundation treats the length as unknown.
    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last, total != "*" else {
            return response.statusCode == 206 ? nil : response.expectedContentLength
        }
        return Int64(total)
    }
}
