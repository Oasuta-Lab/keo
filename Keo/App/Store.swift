import SwiftUI
import UIKit

/// Owns the one thing the whole app depends on: whether we have a usable client.
@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case idle, discovering, waitingForButton, failed(String) }

    @Published private(set) var client: FreeboxClient?
    @Published private(set) var phase: Phase = .idle

    /// La box refuse l'application, et relire le trousseau n'a rien donné de plus frais.
    ///
    /// Séparé de `phase` et surtout de `client`, qu'il ne faut **pas** mettre à nil : la
    /// racine bascule sur l'écran d'appairage dès que le client disparaît, ce qui démonterait
    /// la navigation et couperait l'accès à l'index local — alors que tout ce qui est déjà
    /// indexé reste parfaitement consultable sans la box.
    @Published private(set) var authorizationLost = false

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
        client = build(FreeboxEndpoint(base: base, boxName: boxName), token: token)
    }

    /// Le jeton que porte le client en service. Sert à savoir si le trousseau en a un autre.
    private var tokenInUse: String?

    /// Construit un client branché sur la reprise, et retient son jeton.
    private func build(_ endpoint: FreeboxEndpoint, token: String) -> FreeboxClient {
        tokenInUse = token
        let made = FreeboxClient(endpoint: endpoint, appToken: token) { [weak self] in
            Task { @MainActor in await self?.authorizationRefused() }
        }
        // Sinon l'indexeur reprendrait avec celui que la box vient de refuser : il est retenu
        // dans sa file et dans son observateur de premier plan, et réappairer ne l'en sort pas.
        Indexer.shared.adopt(made)
        return made
    }

    /// Appelé quand la box a refusé l'application et que rouvrir une session n'y a rien fait.
    ///
    /// Avant de dire quoi que ce soit : **relire le trousseau**. C'est là que se trouve la
    /// réparation dans le cas le plus fréquent — un autre appareil du foyer vient de
    /// s'associer, la Freebox ne reconnaît qu'un jeton par application, et le jeton tout neuf
    /// arrive par iCloud quelques minutes plus tard. Sans cette relecture, l'app envoie
    /// appuyer sur ✓ pour un problème qui se serait réglé seul — et ce ✓ révoquerait à son
    /// tour l'autre appareil, en boucle.
    private func authorizationRefused() async {
        if let fresh = Keychain.get(account: host), fresh != tokenInUse,
           let base = URL(string: apiBase) {
            client = build(FreeboxEndpoint(base: base, boxName: boxName), token: fresh)
            authorizationLost = false
            return
        }
        authorizationLost = true
    }

    /// À appeler au retour au premier plan tant que l'autorisation est perdue : le jeton peut
    /// être arrivé entre-temps, et le trousseau iCloud met parfois des minutes.
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
            // Seul un refus *nommé* par la box justifie de jeter la clé. L'ancienne version
            // la supprimait sur n'importe quelle erreur, y compris un simple échec réseau :
            // un premier lancement dans le métro effaçait donc du trousseau iCloud le jeton
            // de tout le foyer.
            Keychain.delete(account: host)
            phase = .idle
        } catch {
            // La box est hors de portée — l'état normal de cette app quand on n'est pas chez
            // soi. On garde la clé et on se tait.
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
            // Un appairage réussi est la seule chose qui efface vraiment l'état : le jeton
            // vient d'être accordé par un geste physique sur la box.
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
