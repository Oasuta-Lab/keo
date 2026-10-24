import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image("Mascot")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .accessibilityLabel("Keo, la loutre qui garde vos photos")

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
            BuildStampLabel().padding(.bottom, 8)
        }
    }
}
