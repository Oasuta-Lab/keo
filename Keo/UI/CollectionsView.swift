import SwiftUI

/// The Collections tab: the list, and everything that manages it.
struct CollectionsView: View {
    let client: FreeboxClient

    @State private var collections: [IndexStore.Collection] = []
    @State private var naming = false
    @State private var renaming: IndexStore.Collection?
    @State private var name = ""

    var body: some View {
        List {
            if collections.isEmpty {
                ContentUnavailableView {
                    Label("Aucune collection", systemImage: "square.stack")
                } description: {
                    Text("Range tes photos par thème. Une photo peut appartenir à plusieurs "
                       + "collections, et rien n'est écrit sur le NAS.")
                } actions: {
                    Button("Nouvelle collection") { startCreating() }
                }
                .listRowBackground(Color.clear)
            }

            ForEach(collections) { collection in
                NavigationLink(value: BrowserSource.collection(id: collection.id,
                                                               name: collection.name)) {
                    LabeledContent(collection.name) {
                        Text(collection.count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        act { try await IndexStore.shared.deleteCollection(collection.id) }
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
        .navigationDestination(for: BrowserSource.self) { destination in
            BrowserView(client: client, source: destination)
        }
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
        .task { await reload() }
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
    }
}
