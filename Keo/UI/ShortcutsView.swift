import SwiftUI

/// The Shortcuts tab: folders pinned for one-tap access, wherever they sit in the tree.
struct ShortcutsView: View {
    let client: FreeboxClient
    @EnvironmentObject private var undoer: Undoer

    @EnvironmentObject private var sync: CloudSync
    @State private var shortcuts: [Item] = []
    @State private var stats: [String: FolderStats] = [:]
    /// Pinned folders the index no longer finds.
    @State private var missing: Set<String> = []

    var body: some View {
        List {
            if shortcuts.isEmpty {
                Group {
                    if sync.status == .recovering {
                        SyncRecoveryView()
                    } else {
                        ContentUnavailableView {
                            Label("Rien d'épinglé", systemImage: "pin")
                        } description: {
                            Text("Garde sous la main les dossiers où tu reviens. Appui long sur un "
                               + "dossier dans Parcourir, puis « Épingler ».")
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            ForEach(shortcuts) { folder in
                NavigationLink(value: BrowserSource.folder(folder)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(folder.name)
                            if missing.contains(folder.path) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(missing.contains(folder.path)
                             ? "Introuvable sur le NAS — balaye pour retirer"
                             : detail(for: folder))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Désépingler", systemImage: "pin.slash", role: .destructive) {
                        Task {
                            try? await IndexStore.shared.setShortcut(folder, false)
                            await reload()
                            undoer.record("« \(folder.name) » dépinglé") {
                                try? await IndexStore.shared.setShortcut(folder, true)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Épinglés")
        .modifier(PushTargets(client: client, declare: true))
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncFootnote() }
        .task { await reload() }
        // Pinning, or undoing one, can happen from another screen entirely.
        .onChange(of: undoer.revision) { _, _ in Task { await reload() } }
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
        return "\(parent) — \(count.formatted()) éléments\(weight)"
    }

    private func reload() async {
        shortcuts = (try? await IndexStore.shared.shortcuts()) ?? []
        stats = (try? await IndexStore.shared.stats(for: shortcuts.map(\.path))) ?? [:]
        // Marked, never removed on its own: the folder may simply not be indexed yet.
        let resolved = try? await IndexStore.shared.resolveFolders(shortcuts)
        missing = Set(resolved?.missing.map(\.path) ?? [])
    }
}
