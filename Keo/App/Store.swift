import SwiftUI
import UIKit

/// Owns the one thing the whole app depends on: whether we have a usable client.
@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case idle, discovering, waitingForButton, failed(String) }

    @Published private(set) var client: FreeboxClient?
    @Published private(set) var phase: Phase = .idle

    @AppStorage("host") var host = "mafreebox.freebox.fr"
    @AppStorage("apiBase") private var apiBase = ""
    @AppStorage("boxName") var boxName = "Freebox"

    private let login = LoginTransport(session: ReadOnlyTransport.makeSession())

    /// Le seul accès global du projet, et il existe pour une raison précise : une tâche
    /// d'arrière-plan n'a pas de vue, donc pas d'environnement SwiftUI, et doit pourtant
    /// savoir si l'app est appairée. Faible, pour ne pas prolonger la vie de ce que
    /// `@StateObject` possède.
    static private(set) weak var shared: Store?

    init() {
        Self.shared = self
        guard let token = Keychain.get(account: host) else { return }
        guard let base = URL(string: apiBase) else { return }
        client = FreeboxClient(endpoint: FreeboxEndpoint(base: base, boxName: boxName),
                               appToken: token)
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
            let candidate = FreeboxClient(endpoint: endpoint, appToken: token)
            _ = try await candidate.list(FreeboxClient.rootPath)   // the token may have been revoked

            apiBase = endpoint.base.absoluteString
            boxName = endpoint.boxName
            client = candidate
            phase = .idle
        } catch {
            // Stale key, or the box is away: fall back to pairing rather than nagging.
            Keychain.delete(account: host)
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

            let client = FreeboxClient(endpoint: endpoint, appToken: request.app_token)
            _ = try await client.list(FreeboxClient.rootPath)   // surfaces a missing permission now
            self.client = client
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
