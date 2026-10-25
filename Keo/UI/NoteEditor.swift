import SwiftUI

/// A note on one photo, video or folder.
///
/// Stored next to the favourites, never on the NAS — the app does not write there, and a
/// sidecar file would be a write. It syncs through the same CloudKit mirror, so a note taken
/// on the phone is on the iPad a few seconds later.
struct NoteEditor: View {
    let item: Item
    /// Hands back what was saved so the caller can refresh without re-querying the store.
    var onSave: (String) -> Void = { _ in }

    @State private var body_ = ""
    @State private var loaded = false
    @State private var failure: String?
    @FocusState private var writing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $body_)
                        .focused($writing)
                        .frame(minHeight: 160)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if body_.isEmpty {
                                Text("Ce que tu veux retrouver plus tard")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "photo")
                        .lineLimit(1)
                } footer: {
                    Text("Cherchable depuis l'onglet Recherche, et synchronisée avec tes autres "
                       + "appareils. Rien n'est écrit sur le NAS.")
                }
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(!loaded)
                }
            }
            .task {
                body_ = (try? await IndexStore.shared.note(on: item)) ?? ""
                loaded = true
                // Straight to the keyboard on a new note; an existing one is often reread
                // rather than rewritten, so leave it alone.
                writing = body_.isEmpty
            }
            .alert("Note non enregistrée", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func save() {
        let text = body_
        Task {
            do {
                try await IndexStore.shared.setNote(text, on: item)
                onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The mark an annotated item carries in a grid or on a tile. Small on purpose: it says
/// "there is something here", it does not compete with the photo.
struct NoteBadge: View {
    var body: some View {
        Image(systemName: "text.quote")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
            .padding(5)
            .accessibilityLabel("Contient une note")
    }
}
