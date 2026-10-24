import SwiftUI

/// Where the long, boring work is visible and under control, instead of hiding behind a chip
/// that restarts every time you change folder.
struct IndexingView: View {
    let client: FreeboxClient

    @EnvironmentObject private var indexer: Indexer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let progress = indexer.state.progress {
                        report(progress)
                    } else {
                        Label("Jamais lancée", systemImage: "clock.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("État")
                } footer: {
                    if let last = indexer.lastRun {
                        Text("Dernier passage complet : \(last.formatted(date: .abbreviated, time: .shortened))")
                    }
                }

                Section {
                    if indexer.state.isRunning {
                        Button("Arrêter", systemImage: "stop.fill", role: .destructive) {
                            indexer.stop()
                        }
                        .tint(.red)   // sinon l'icône garde la couleur d'accent, le texte est rouge
                    } else {
                        Button("Lancer l'indexation", systemImage: "play.fill") {
                            indexer.start(client: client)
                        }
                        Button("Tout réindexer", systemImage: "arrow.clockwise") {
                            indexer.start(client: client, restart: true)
                        }
                    }
                } footer: {
                    Text("Keo lit les 4 premiers kilo-octets de chaque photo pour en extraire la "
                       + "date de prise de vue. Une photo déjà lue n'est jamais relue, même après "
                       + "un arrêt : relancer reprend là où ça s'était arrêté.\n\n"
                       + "Un dossier déjà indexé n'est réexaminé que s'il a changé : Keo compare "
                       + "sa date de modification, qui bouge dès qu'une photo y est ajoutée. "
                       + "Ajouter des photos ne demande donc jamais de tout réindexer — seules "
                       + "les nouvelles sont lues.\n\n"
                       + "L'indexation se met en pause quand tu quittes l'app et reprend au retour. "
                       + "Elle continue pendant que tu navigues, en laissant la priorité aux vignettes.")
                }
            }
            .alert("Index inaccessible", isPresented: Binding(
                get: { indexer.failure != nil },
                set: { if !$0 { indexer.failure = nil } }
            )) {
                Button("OK") { indexer.failure = nil }
            } message: {
                Text(indexer.failure ?? "")
            }
            .navigationTitle("Indexation des dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func report(_ progress: Indexer.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if indexer.state.isRunning {
                Text((progress.folder as NSString).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The folder's own bar: a global one barely twitches on a 14 600 photo folder.
                if progress.folderTotal > 0 {
                    ProgressView(value: progress.folderFraction)
                    Text("\(progress.folderDone.formatted()) / \(progress.folderTotal.formatted()) dans ce dossier")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Lecture du dossier…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Terminée", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)

        row("Dossiers parcourus", progress.foldersVisited)
        row("Déjà indexés, ignorés", progress.foldersSkipped)
        row("Dates lues cette fois", progress.datesRead)
        row("Restantes ici", max(progress.folderTotal - progress.folderDone, 0))
        if progress.adopted > 0 {
            LabeledContent("Retrouvées après déplacement") {
                Text(progress.adopted, format: .number).monospacedDigit()
            }
        }
        row("Dates connues au total", max(progress.indexedOverall, 0))
        if progress.unreadable > 0 {
            LabeledContent("Illisibles, à réessayer") {
                Text(progress.unreadable, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        LabeledContent(label) {
            Text(value, format: .number)
                .monospacedDigit()
        }
    }
}

/// Shown when a folder has more undated files than is reasonable to read on the fly.
struct UnindexedChip: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("\(count) photos sans date · Indexer")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The global pass, visible from wherever you are browsing.
struct IndexingChip: View {
    let fraction: Double
    let pending: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("Indexation · \(pending) restantes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
