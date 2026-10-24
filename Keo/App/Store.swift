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

    init() {
        guard let base = URL(string: apiBase), let token = Keychain.get(account: host) else { return }
        client = FreeboxClient(endpoint: FreeboxEndpoint(base: base, boxName: boxName),
                               appToken: token)
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
