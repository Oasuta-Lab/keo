import Security
import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    NavigationStack {
                        BrowserView(client: client, url: client.root, title: store.serverName)
                    }
                } else {
                    ConnectView()
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published private(set) var client: DAVClient?
    @Published private(set) var serverName = "NAS"

    @AppStorage("server") var address = ""
    @AppStorage("user") var username = ""

    init() {
        guard let url = URL(string: address), !username.isEmpty,
              let password = Keychain.get(account: username) else { return }
        client = DAVClient(root: url, username: username, password: password)
        serverName = url.host ?? "NAS"
    }

    func connect(address: String, username: String, password: String) async throws {
        guard let url = Self.normalize(address) else { throw URLError(.badURL) }
        let client = DAVClient(root: url, username: username, password: password)
        _ = try await client.list(client.root)

        self.address = url.absoluteString
        self.username = username
        Keychain.set(password, account: username)
        self.serverName = url.host ?? "NAS"
        self.client = client
    }

    func signOut() {
        Keychain.delete(account: username)
        address = ""
        username = ""
        client = nil
    }

    /// Accepts "nas.local/dav", "192.168.1.20:5005/home", "https://…" — plain LAN hosts default to http.
    private static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let isLocal = host.hasSuffix(".local") || host.hasPrefix("192.168.")
                || host.hasPrefix("10.") || host.hasPrefix("172.")
            text = (isLocal ? "http://" : "https://") + text
        }
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text)
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

// MARK: - Connect

struct ConnectView: View {
    @EnvironmentObject private var store: Store

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("nas.local/dav", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Utilisateur", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Mot de passe", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Adresse WebDAV du NAS")
                } footer: {
                    Text("Synology : Panneau de configuration → Services de fichiers → WebDAV. "
                         + "Le mot de passe est stocké dans le trousseau iOS.")
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Se connecter")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || address.isEmpty || username.isEmpty)
            }
            .navigationTitle("Keo")
        }
    }

    private func connect() async {
        busy = true
        error = nil
        do {
            try await store.connect(address: address, username: username, password: password)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
