import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        content
            // A reinstall still holds the key; only the address was lost with UserDefaults.
            .task { await store.reconnectIfPossible() }
    }

    private var content: some View {
        VStack(spacing: 28) {
            Spacer()

            CageMark.Filled(height: 110).foregroundStyle(.tint)

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
                    // The label colour SwiftUI picks for a prominent button assumes a
                    // dark fill. Keo's accent is a pale peach in dark mode, where white
                    // on it falls to 2.1:1 — `OnAccent` flips with the appearance.
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color("OnAccent"))
                    .controlSize(.large)

                    // The accepted trade-off, said once where the authorization is created.
                    Text("L'autorisation suit le trousseau iCloud : tes autres appareils "
                       + "n'auront pas à appuyer sur ✓. La Freebox n'en voit qu'une, elle se "
                       + "retire donc pour tous à la fois.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
            BuildStampLabel().padding(.bottom, 8)
        }
    }
}
