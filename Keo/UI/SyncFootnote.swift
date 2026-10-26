import SwiftUI

/// One quiet line at the foot of the personalisation tabs — the only places sync matters.
/// Same family as the indexing chips: informative, never modal, never a dialog. The Freebox
/// user without iCloud reads one calm sentence, not a nag.
///
/// It says nothing at all when there is nothing to say. « Synchronisé avec iCloud » and « sans
/// iCloud » are steady states: true for months, asking for nothing, and a permanent line that
/// is permanently reassuring is furniture — the same disease the home row had with its folder
/// ratio. What the other screens keep is the transient half: a recovery in flight, a sync
/// running, a device offline, an error. Those are worth a line precisely because they end.
///
/// `reassures` turns the steady states back on, and exactly one screen asks for it. The home
/// screen is the room where the state of the library is surveyed — the Bibliothèque card is
/// right above — and « tout est à sa place » is what someone comes there to read.
struct SyncFootnote: View {
    /// Say the calm states too. The home screen only.
    var reassures = false

    @EnvironmentObject private var sync: CloudSync

    /// A steady state on a screen that did not ask to be reassured.
    private var silent: Bool {
        guard !reassures else { return false }
        switch sync.status {
        case .upToDate, .off: return true
        default: return false
        }
    }

    var body: some View {
        if silent {
            // Zero height, so the `safeAreaInset` that holds it collapses with it rather than
            // leaving a band of padding behind.
            EmptyView()
        } else {
            line
        }
    }

    private var line: some View {
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
