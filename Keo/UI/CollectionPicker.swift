import SwiftUI

/// Choosing a collection for a selection, from the grid or from the full-screen viewer.
///
/// It used to be a bare `confirmationDialog` over the list of collections. With no collection
/// yet, that dialog had nothing but « Annuler » to show — iOS renders an action sheet with no
/// actions badly, and the title drifts to a corner. The dead end was the real bug: the answer
/// to "add to a collection" when you have none is to make one, not to be shown an empty menu
/// and sent to another tab.
struct CollectionPicker: ViewModifier {
    @Binding var choosing: Bool
    let collections: [IndexStore.Collection]
    let add: (IndexStore.Collection) -> Void
    let create: (String) -> Void

    @State private var naming = false
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            // Straight to naming when there is nothing to choose from.
            .onChange(of: choosing) { _, now in
                guard now, collections.isEmpty else { return }
                choosing = false
                name = ""
                naming = true
            }
            .confirmationDialog("Ajouter à une collection",
                                isPresented: Binding(get: { choosing && !collections.isEmpty },
                                                     set: { choosing = $0 }),
                                titleVisibility: .visible) {
                ForEach(collections) { collection in
                    Button(collection.name) { add(collection) }
                }
                // Also here when collections exist: making one used to mean leaving for the
                // Collections tab and losing the selection on the way.
                Button("Nouvelle collection…") {
                    name = ""
                    naming = true
                }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Nouvelle collection", isPresented: $naming) {
                TextField("Nom", text: $name)
                Button("Annuler", role: .cancel) { naming = false }
                Button("Créer") {
                    let typed = name
                    naming = false
                    guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    create(typed)
                }
            } message: {
                Text("Les photos sélectionnées y seront ajoutées.")
            }
    }
}

extension View {
    func collectionPicker(choosing: Binding<Bool>,
                          collections: [IndexStore.Collection],
                          add: @escaping (IndexStore.Collection) -> Void,
                          create: @escaping (String) -> Void) -> some View {
        modifier(CollectionPicker(choosing: choosing, collections: collections,
                                  add: add, create: create))
    }
}
