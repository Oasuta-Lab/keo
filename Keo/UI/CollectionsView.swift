import SwiftUI

/// The Collections tab: the list, and everything that manages it.
struct CollectionsView: View {
    let client: FreeboxClient
    @EnvironmentObject private var undoer: Undoer

    @EnvironmentObject private var sync: CloudSync
    @State private var collections: [IndexStore.Collection] = []
    /// Without it the empty state flashes on the first frame, before the first read has
    /// returned — the browser already guards its own the same way.
    @State private var loaded = false
    @State private var naming = false
    /// Deleting a collection is the one piece of personalisation the undo stack cannot take
    /// back, so it is the one that asks.
    @State private var deleting: IndexStore.Collection?
    @State private var renaming: IndexStore.Collection?
    @State private var name = ""

    var body: some View {
        List {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if collections.isEmpty {
                Group {
                    if sync.status == .recovering {
                        SyncRecoveryView()
                    } else {
                        ContentUnavailableView {
                            Label("Aucune collection", systemImage: "square.stack")
                        } description: {
                            Text("Range tes photos par thème. Une photo peut appartenir à plusieurs "
                               + "collections, et rien n'est écrit sur le NAS.")
                        } actions: {
                            Button("Nouvelle collection") { startCreating() }
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            ForEach(collections) { collection in
                NavigationLink(value: BrowserSource.collection(id: collection.id,
                                                               name: collection.name)) {
                    // Worded, because this is a row of text and not a badge on an image:
                    // a bare number beside a name leaves the reader to guess what it counts.
                    LabeledContent(collection.name) {
                        Text(Undoer.count(collection.count, "élément", "éléments"))
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        deleting = collection
                    }
                    Button("Renommer", systemImage: "pencil") {
                        renaming = collection
                        name = collection.name
                    }
                    .tint(.indigo)
                }
            }
        }
        .navigationTitle("Collections")
        // Inline like every other tab's. A large title draws on its own line *below* the bar,
        // which put this one lower than the others rather than higher.
        .navigationBarTitleDisplayMode(.inline)
        // Favoris and Parcourir both pull to refresh; a collection arriving from another
        // device is exactly the case that wants it.
        .refreshable { await reload() }
        // Every other personalisation — épingler, favoriser, annoter — is reversible by
        // shaking. This one is not: the collection and its contents go together.
        .confirmationDialog(Text("Supprimer « \(deleting?.name ?? "") » ?"),
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            // The name belongs in the title, which wraps. A button label does not: a long
            // collection name was simply cut off mid-word.
            Button("Supprimer", role: .destructive) {
                guard let doomed = deleting else { return }
                act { try await IndexStore.shared.deleteCollection(doomed.id) }
                deleting = nil
            }
            Button("Annuler", role: .cancel) { deleting = nil }
        } message: {
            Text("Les photos restent sur le NAS. Seul le rangement disparaît.")
        }
        .modifier(PushTargets(client: client, declare: true))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nouvelle collection", systemImage: "plus") { startCreating() }
            }
        }
        .alert(renaming == nil ? "Nouvelle collection" : "Renommer",
               isPresented: Binding(get: { naming || renaming != nil },
                                    set: { if !$0 { naming = false; renaming = nil } })) {
            TextField("Nom", text: $name)
            Button("Annuler", role: .cancel) { naming = false; renaming = nil }
            Button("Valider") {
                let typed = name
                let target = renaming
                naming = false
                renaming = nil
                act {
                    if let target {
                        try await IndexStore.shared.renameCollection(target.id, to: typed)
                    } else {
                        try await IndexStore.shared.createCollection(named: typed)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncFootnote() }
        .task { await reload() }
        // Pinning, or undoing one, can happen from another screen entirely.
        .onChange(of: undoer.revision) { _, _ in Task { await reload() } }
        // A collection created on another device lands without a tap here: repaint on each
        // sync transition rather than waiting for the next visit.
        .onChange(of: sync.status) { Task { await reload() } }
    }

    private func startCreating() {
        renaming = nil
        name = ""
        naming = true
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            try? await work()
            await reload()
        }
    }

    private func reload() async {
        collections = (try? await IndexStore.shared.collections()) ?? []
        loaded = true
    }
}
