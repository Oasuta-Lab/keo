import SwiftUI

/// Where the long, boring work is visible and under control, instead of hiding behind a chip
/// that restarts every time you change folder.
struct IndexingView: View {
    let client: FreeboxClient

    @EnvironmentObject private var indexer: Indexer
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingRebuild = false
    @State private var knownCount = 0
    #if DEBUG
    @State private var bench: (path: String, count: Int)?
    @State private var benching = false
    @State private var benchResult: [ReadBench.Run] = []
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let progress = indexer.state.progress {
                        report(progress)
                    } else if knownCount > 0 {
                        Label("\(knownCount.formatted()) fichiers indexés",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Pas encore commencée", systemImage: "clock.badge.questionmark")
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
                    // `isStalled` guards against a state that says "running" with no worker
                    // behind it: that used to hide the only button able to restart.
                    if indexer.state.isRunning, !indexer.isStalled {
                        Button(role: .destructive) {
                            indexer.stop()
                        } label: {
                            // Explicit style: a destructive role colours the text but leaves the
                            // icon on the accent tint, which reads as a glitch.
                            Label("Arrêter", systemImage: "stop.fill")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button(indexer.state.isPaused || indexer.isStalled
                               ? "Reprendre" : "Lancer l'indexation",
                               systemImage: "play.fill") {
                            indexer.start(client: client)
                        }
                        Button("Revérifier tous les dossiers",
                               systemImage: "arrow.clockwise") {
                            indexer.start(client: client, scope: .recheck)
                        }

                        Button(role: .destructive) {
                            confirmingRebuild = true
                        } label: {
                            Label("Tout relire depuis zéro", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text("Keo parcourt le NAS et retient ce qu'il y trouve : la structure des "
                       + "dossiers, les fichiers, leurs tailles, et la date de prise de vue de "
                       + "chaque photo et vidéo — lue dans les premiers kilo-octets du fichier, "
                       + "jamais en le téléchargeant.\n\n"
                       + "C'est cet index qui permet le tri chronologique, la timeline, les "
                       + "totaux sur les dossiers, et leur ouverture instantanée.\n\n"
                       + "Un fichier déjà lu n'est jamais relu, même après un arrêt : relancer "
                       + "reprend là où ça s'était arrêté.\n\n"
                       + "« Revérifier » reliste tous les dossiers sans relire un seul fichier. "
                       + "« Tout relire depuis zéro » efface l'index et recommence vraiment.\n\n"
                       + "Un dossier déjà indexé n'est réexaminé que s'il a changé : Keo compare "
                       + "sa date de modification, qui bouge dès qu'une photo y est ajoutée. "
                       + "Ajouter des photos ne demande donc jamais de tout réindexer — seules "
                       + "les nouvelles sont lues.\n\n"
                       + "L'indexation se met en pause quand tu quittes l'app et reprend au retour. "
                       + "Elle continue pendant que tu navigues, en laissant la priorité aux vignettes.")
                }

                #if DEBUG
                benchSection
                #endif
            }
            .alert("Index inaccessible", isPresented: Binding(
                get: { indexer.failure != nil },
                set: { if !$0 { indexer.failure = nil } }
            )) {
                Button("OK") { indexer.failure = nil }
            } message: {
                Text(indexer.failure ?? "")
            }
            .task {
                knownCount = (try? await IndexStore.shared.fileCount()) ?? 0
                #if DEBUG
                bench = try? await IndexStore.shared.largestFolder()
                #endif
            }
            .confirmationDialog("Tout relire depuis zéro ?", isPresented: $confirmingRebuild,
                                titleVisibility: .visible) {
                Button("Effacer et tout relire", role: .destructive) {
                    indexer.start(client: client, scope: .rebuild)
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text(rebuildWarning)
            }
            .navigationTitle("Indexation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    /// Says what it costs, in the user's own numbers, before anything is thrown away.
    #if DEBUG
    /// Debug builds only: `Indexer.parallel = 3` was a cautious guess, never measured.
    /// One tap, then read the `[keo] bench:` lines off the device console.
    @ViewBuilder
    private var benchSection: some View {
        Section {
            if let bench {
                Button(benching ? "Mesure en cours…" : "Mesurer les lectures",
                       systemImage: "speedometer") {
                    measure(bench.path)
                }
                .disabled(benching || indexer.state.isRunning)

                ForEach(benchResult, id: \.parallel) { run in
                    Text(run.line)
                        .font(.system(size: 11, design: .monospaced))
                }
            } else {
                Text("Rien d'indexé à mesurer")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Banc d'essai (debug)")
        } footer: {
            if let bench {
                Text("Lit des prefixes de 24 Ko dans « \(bench.path) » (\(bench.count) photos et vidéos) "
                   + "à plusieurs niveaux de parallélisme, chacun sur des fichiers différents "
                   + "pour ne pas mesurer le cache de la box. N'écrit rien, ni sur le NAS ni "
                   + "dans l'index.")
            }
        }
    }

    private func measure(_ folder: String) {
        benching = true
        benchResult = []
        Task {
            benchResult = await ReadBench.run(folder: folder, client: client)
            benching = false
        }
    }
    #endif

    private var rebuildWarning: String {
        let dates = knownCount.formatted()
        return "Les \(dates) dates déjà lues seront effacées, puis chaque photo sera relue "
             + "une par une sur le NAS. Compte plusieurs minutes par millier de photos.\n\n"
             + "À ne faire que si les dates affichées sont fausses. Pour simplement détecter "
             + "des photos ajoutées, « Revérifier tous les dossiers » suffit et ne relit rien."
    }

    @ViewBuilder
    private func report(_ progress: Indexer.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if indexer.state.isRunning, !indexer.isStalled {
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
            } else if indexer.state.isPaused || indexer.isStalled {
                Label("En pause — reprend là où elle s'est arrêtée",
                      systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
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
        if progress.dateless > 0 {
            row("Sans date de prise de vue", progress.dateless)
        }
        if progress.unreachable > 0 {
            problemLink("Dossiers injoignables", count: progress.unreachable,
                        problems: progress.problems.filter { $0.trouble == .folderUnreachable })
        }
        if progress.unreadable > 0 {
            problemLink("Illisibles, à réessayer", count: progress.unreadable,
                        problems: progress.problems.filter { $0.trouble == .fileUnreadable })
        }
    }

    /// Tappable only when there is something to show: the list is capped, so a very large
    /// failure keeps its honest count while detailing only the first entries.
    @ViewBuilder
    private func problemLink(_ label: String, count: Int,
                             problems: [Indexer.Problem]) -> some View {
        if problems.isEmpty {
            LabeledContent(label) {
                Text(count, format: .number).monospacedDigit().foregroundStyle(.orange)
            }
        } else {
            NavigationLink {
                ProblemList(title: label, total: count, problems: problems)
            } label: {
                LabeledContent(label) {
                    Text(count, format: .number).monospacedDigit().foregroundStyle(.orange)
                }
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
            // The capsule is about 32 pt tall; the tap target has to reach 44 without the
            // chip itself growing into the grid.
            .contentShape(Capsule().inset(by: -8))
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
            // The capsule is about 32 pt tall; the tap target has to reach 44 without the
            // chip itself growing into the grid.
            .contentShape(Capsule().inset(by: -8))
        }
        .buttonStyle(.plain)
    }
}


/// The detail behind a failure count.
private struct ProblemList: View {
    let title: String
    let total: Int
    let problems: [Indexer.Problem]

    var body: some View {
        List {
            Section {
                ForEach(problems) { problem in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.name)
                            .font(.subheadline.weight(.medium))
                        Text((problem.path as NSString).deletingLastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(problem.reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                if total > problems.count {
                    Text("\(total.formatted()) au total, les \(problems.count) premiers sont "
                       + "listés ici.\n\nCes entrées ne sont pas perdues : elles restent à lire "
                       + "et seront réessayées au prochain passage.")
                } else {
                    Text("Ces entrées ne sont pas perdues : elles restent à lire et seront "
                       + "réessayées au prochain passage.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
