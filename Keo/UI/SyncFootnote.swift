import SwiftUI

/// One quiet line at the foot of the personalisation tabs — the only places sync matters.
/// Same family as the indexing chips: informative, never modal, never a dialog. The Freebox
/// user without iCloud reads one calm sentence, not a nag.
struct SyncFootnote: View {
    @EnvironmentObject private var sync: CloudSync

    var body: some View {
        HStack(spacing: 6) {
            switch sync.status {
            case .off:
                Image(systemName: "icloud.slash")
                Text("Sans iCloud — tout reste sur cet appareil")
            case .recovering:
                ProgressView()
                    .controlSize(.mini)
                Text("Récupération depuis iCloud…")
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                Text("Synchronisation…")
            case .upToDate:
                Image(systemName: "checkmark.icloud")
                Text("Synchronisé avec iCloud")
            case .offline:
                Image(systemName: "icloud.slash")
                Text("Hors ligne — sera synchronisé plus tard")
            case .error(let message):
                Image(systemName: "exclamationmark.icloud")
                Text(message)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// What an empty personalisation tab shows while the first fetch after a reinstall is still
/// running: "empty because nothing has arrived yet" must never look like "empty because there
/// is nothing" — the user would believe everything is lost and start over on top of it.
struct SyncRecoveryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Récupération en cours", systemImage: "icloud.and.arrow.down")
        } description: {
            Text("Tes favoris, épingles et collections reviennent d'iCloud. "
               + "Rien n'est perdu.")
        }
    }
}
