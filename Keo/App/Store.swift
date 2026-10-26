import SwiftUI
import UIKit

/// Owns the one thing the whole app depends on: whether we have a usable client.
@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case idle, discovering, waitingForButton, failed(String) }

    @Published private(set) var client: FreeboxClient?
    @Published private(set) var phase: Phase = .idle

    /// The box refuses the application, and rereading the keychain gave nothing fresher.
    ///
    /// Separate from `phase` and above all from `client`, which must **not** be set to nil:
    /// the root switches to the pairing screen the moment the client disappears, which would
    /// tear down the navigation and cut off the local index — even though everything already
    /// indexed stays perfectly browsable without the box.
    @Published private(set) var authorizationLost = false

    @AppStorage("host") var host = "mafreebox.freebox.fr"
    @AppStorage("apiBase") private var apiBase = ""
    @AppStorage("boxName") var boxName = "Freebox"

    private let login = LoginTransport(session: ReadOnlyTransport.makeSession())

    /// The project's only global access, and it exists for a precise reason: a background
    /// task has no view, hence no SwiftUI environment, and still has to know whether the app
    /// is paired. Weak, so it never extends the life of what `@StateObject` owns.
    static private(set) weak var shared: Store?

    init() {
        Self.shared = self
        guard let token = Keychain.get(account: host) else { return }
        guard let base = URL(string: apiBase) else { return }
        client = build(FreeboxEndpoint(base: base, boxName: boxName), token: token)
    }

    /// The token the client in service carries. Tells whether the keychain holds another one.
    private var tokenInUse: String?

    /// Builds a client wired into the recovery path, and remembers its token.
    private func build(_ endpoint: FreeboxEndpoint, token: String) -> FreeboxClient {
        tokenInUse = token
        let made = FreeboxClient(endpoint: endpoint, appToken: token) { [weak self] in
            Task { @MainActor in await self?.authorizationRefused() }
        }
        // Otherwise the indexer would resume with the one the box just refused: it is held
        // in its queue and in its foreground observer, and re-pairing does not pull it out.
        Indexer.shared.adopt(made)
        return made
    }

    /// Called when the box has refused the application and reopening a session fixed nothing.
    ///
    /// Before saying anything: **reread the keychain**. That is where the repair lives in the
    /// most frequent case — another device in the household just paired, the Freebox only
    /// recognises one token per application, and the brand-new token arrives through iCloud a
    /// few minutes later. Without this reread, the app sends someone to press ✓ for a problem
    /// that would have fixed itself — and that ✓ would in turn revoke the other device, in a
    /// loop.
    private func authorizationRefused() async {
        if let fresh = Keychain.get(account: host), fresh != tokenInUse,
           let base = URL(string: apiBase) {
            client = build(FreeboxEndpoint(base: base, boxName: boxName), token: fresh)
            authorizationLost = false
            return
        }
        authorizationLost = true
    }

    /// To call on return to the foreground while authorization is lost: the token may have
    /// arrived in the meantime, and the iCloud Keychain sometimes takes minutes.
    func retryWithFreshToken() async {
        guard authorizationLost else { return }
        await authorizationRefused()
    }

    /// Reconnects without asking the box again after a reinstall — or on a device that has
    /// never been paired at all, since the token now arrives through the iCloud Keychain.
    ///
    /// The app token survives in the keychain, but the API address lived in `UserDefaults`,
    /// which is wiped with the app — so Keo asked for a new pairing while already holding the
    /// key. The address needs no authentication to rediscover, so there is nothing to ask.
    func reconnectIfPossible() async {
        guard client == nil, phase == .idle, apiBase.isEmpty else { return }

        // A device that has just joined the iCloud Keychain gets the token a few seconds after
        // launch. Reading once would miss it and send someone to press ✓ on the box for nothing;
        // the pairing button stays live throughout and its tap ends this wait.
        for _ in 0..<15 where Keychain.get(account: host) == nil {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard client == nil, phase == .idle, let token = Keychain.get(account: host) else { return }

        phase = .discovering
        do {
            let endpoint = try await FreeboxEndpoint.discover(host: host, using: login)
            let candidate = build(endpoint, token: token)
            _ = try await candidate.list(FreeboxClient.rootPath)   // the token may have been revoked

            apiBase = endpoint.base.absoluteString
            boxName = endpoint.boxName
            client = candidate
            authorizationLost = false
            phase = .idle
        } catch let error as FreeboxError where error.isAuthorizationLost {
            // Only a refusal *named* by the box justifies throwing the key away. The old
            // version deleted it on any error, including a plain network failure: a first
            // launch on the métro therefore wiped the whole household's token from the
            // iCloud Keychain.
            Keychain.delete(account: host)
            phase = .idle
        } catch {
            // The box is out of reach — this app's normal state away from home. Keep the
            // key and say nothing.
            phase = .idle
        }
    }

    func pair() async {
        phase = .discovering
        do {
            let endpoint = try await FreeboxEndpoint.discover(host: host, using: login)
            let request = try await Pairing.start(endpoint, deviceName: UIDevice.current.name,
                                                  using: login)

            phase = .waitingForButton
            try await waitForGrant(endpoint, trackID: request.track_id)

            // Keep the token before validating: a failed first listing shouldn't cost another
            // trip to the box's front panel.
            Keychain.set(request.app_token, account: host)
            apiBase = endpoint.base.absoluteString
            boxName = endpoint.boxName

            let client = build(endpoint, token: request.app_token)
            _ = try await client.list(FreeboxClient.rootPath)   // surfaces a missing permission now
            self.client = client
            // A successful pairing is the only thing that truly clears the state: the token
            // was just granted by a physical gesture on the box.
            authorizationLost = false
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        Keychain.delete(account: host)
        apiBase = ""
        client = nil
        phase = .idle
        // Otherwise the banner outlives the pairing it was about, and sits on top of
        // ConnectView offering to retry a connection that no longer has a token.
        authorizationLost = false
    }

    /// The box shows its prompt for about a minute and a half before giving up.
    private func waitForGrant(_ endpoint: FreeboxEndpoint, trackID: Int) async throws {
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            switch try await Pairing.status(endpoint, trackID: trackID, using: login) {
            case "granted": return
            case "pending": continue
            case "denied": throw FreeboxError.denied
            default: throw FreeboxError.pairingTimedOut
            }
        }
        throw FreeboxError.pairingTimedOut
    }
}
