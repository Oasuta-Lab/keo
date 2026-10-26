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
    @EnvironmentObject private var undoer: Undoer

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
        let item = item
        Task {
            do {
                // Captured before the write, because clearing the text deletes the note and
                // there would be nothing left to read it back from.
                let previous = (try? await IndexStore.shared.note(on: item)) ?? ""
                try await IndexStore.shared.setNote(text, on: item)
                let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(kept)
                dismiss()
                guard kept != previous else { return }
                undoer.record(kept.isEmpty ? "Note supprimée" : "Note enregistrée") {
                    try? await IndexStore.shared.setNote(previous, on: item)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// What a thumbnail says about itself without being opened: it is a favourite, it is in a
/// collection, it carries a note, it is a Live Photo.
///
/// One row rather than four separate overlays, and nothing at all when none applies — four
/// badges on a 110 pt cell would bury the photo they are meant to annotate.
struct Badges: View {
    var noted = false
    var favourite = false
    var collected = false
    var live = false

    private var marks: [(symbol: String, label: String)] {
        var all: [(String, String)] = []
        if live { all.append(("livephoto", "Photo live")) }
        if favourite { all.append(("heart.fill", "Favori")) }
        if collected { all.append(("square.stack.fill", "Dans une collection")) }
        if noted { all.append(("text.quote", "Contient une note")) }
        return all
    }

    var body: some View {
        if !marks.isEmpty {
            HStack(spacing: 3) {
                ForEach(marks, id: \.symbol) { mark in
                    Image(systemName: mark.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityLabel(mark.label)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(Theme.Scrim.chip), in: Capsule())
            .padding(5)
            .allowsHitTesting(false)
        }
    }
}
