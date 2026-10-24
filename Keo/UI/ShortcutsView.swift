import SwiftUI

/// The Shortcuts tab: folders pinned for one-tap access, wherever they sit in the tree.
struct ShortcutsView: View {
    let client: FreeboxClient

    @EnvironmentObject private var sync: CloudSync
    @State private var shortcuts: [Item] = []
    @State private var stats: [String: FolderStats] = [:]

    var body: some View {
        List {
            if shortcuts.isEmpty {
                Group {
                    if sync.status == .recovering {
                        SyncRecoveryView()
                    } else {
                        ContentUnavailableView {
                            Label("Aucun raccourci", systemImage: "star")
                        } description: {
                            Text("Garde sous la main les dossiers où tu reviens. Appui long sur un "
                               + "dossier dans Parcourir, puis « Ajouter aux raccourcis ».")
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            ForEach(shortcuts) { folder in
                NavigationLink(value: BrowserSource.folder(folder)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.name)
                        Text(detail(for: folder))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Retirer", systemImage: "star.slash", role: .destructive) {
                        Task {
                            try? await IndexStore.shared.setShortcut(folder, false)
                            await reload()
                        }
                    }
                }
            }
        }
        .navigationTitle("Raccourcis")
        .navigationDestination(for: BrowserSource.self) { destination in
            BrowserView(client: client, source: destination)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncFootnote() }
        .task { await reload() }
        // Shortcuts arrived from another device land without a tap here: repaint on each
        // sync transition rather than waiting for the next visit.
        .onChange(of: sync.status) { Task { await reload() } }
    }

    /// The parent path, plus what the index already counted — the same figures as the tiles.
    private func detail(for folder: Item) -> String {
        let parent = (folder.path as NSString).deletingLastPathComponent
        guard let stats = stats[folder.path], let count = stats.mediaCount, count > 0 else {
            return parent
        }
        let weight = stats.bytes.map { " · \($0.formatted(.byteCount(style: .file)))" } ?? ""
        return "\(parent) — \(count.formatted()) médias\(weight)"
    }

    private func reload() async {
        shortcuts = (try? await IndexStore.shared.shortcuts()) ?? []
        stats = (try? await IndexStore.shared.stats(for: shortcuts.map(\.path))) ?? [:]
    }
}
