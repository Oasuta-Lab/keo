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
                    } else {
                        Button("Lancer l'indexation", systemImage: "play.fill") {
                            indexer.start(client: client)
                        }
                    }
                } footer: {
                    Text("Keo lit les 4 premiers kilo-octets de chaque photo pour en extraire la "
                       + "date de prise de vue. Une photo déjà lue n'est jamais relue, même après "
                       + "un arrêt : relancer reprend là où ça s'était arrêté.\n\n"
                       + "L'indexation continue pendant que tu navigues, et laisse volontairement "
                       + "la priorité à l'affichage des vignettes.")
                }
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
        VStack(alignment: .leading, spacing: 10) {
            if indexer.state.isRunning {
                ProgressView(value: progress.fraction)
                Text(progress.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Label("Terminée", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)

        row("Dossiers parcourus", progress.foldersVisited)
        row("Photos et vidéos vues", progress.mediaFound)
        row("Dates lues cette fois", progress.datesRead)
        row("Déjà connues", progress.alreadyKnown)
        row("Restantes", progress.pending)
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
