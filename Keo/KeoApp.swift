import Security
import SwiftUI
import UIKit

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    NavigationStack {
                        BrowserView(client: client, path: FreeboxClient.rootPath,
                                    title: store.boxName)
                    }
                } else {
                    ConnectView()
                }
            }
            .environmentObject(store)
            .environmentObject(downloader)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case idle, discovering, waitingForButton, failed(String) }

    @Published private(set) var client: FreeboxClient?
    @Published private(set) var phase: Phase = .idle

    @AppStorage("host") var host = "mafreebox.freebox.fr"
    @AppStorage("apiBase") private var apiBase = ""
    @AppStorage("boxName") var boxName = "Freebox"

    init() {
        guard let base = URL(string: apiBase), let token = Keychain.get(account: host) else { return }
        client = FreeboxClient(endpoint: FreeboxEndpoint(base: base, boxName: boxName),
                               appToken: token)
    }

    func pair() async {
        phase = .discovering
        do {
            let endpoint = try await FreeboxEndpoint.discover(host: host)
            let request = try await Pairing.start(endpoint, deviceName: UIDevice.current.name)

            phase = .waitingForButton
            try await waitForGrant(endpoint, trackID: request.track_id)

            // Keep the token before validating: a failed first listing shouldn't cost
            // another trip to the box's front panel.
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
            switch try await Pairing.status(endpoint, trackID: trackID) {
            case "granted": return
            case "pending": continue
            case "denied": throw FreeboxError.denied
            default: throw FreeboxError.pairingTimedOut
            }
        }
        throw FreeboxError.pairingTimedOut
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "fr.yieldstudio.keo"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: - Pairing screen

struct ConnectView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Keo").font(.largeTitle.bold())
                Text("Tes photos et vidéos, depuis la Freebox.")
                    .foregroundStyle(.secondary)
            }

            switch store.phase {
            case .waitingForButton:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Appuie sur « ✓ » sur l'écran de la Freebox")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Le message s'affiche sur la face avant du Freebox Server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

            case .discovering:
                ProgressView()

            default:
                VStack(spacing: 16) {
                    TextField("mafreebox.freebox.fr", text: $store.host)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button("Associer à la Freebox") {
                        Task { await store.pair() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 32)
            }

            if case .failed(let message) = store.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }
}
