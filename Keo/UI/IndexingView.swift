import SwiftUI

/// Where the long, boring work is visible and under control, instead of hiding behind a chip
/// that restarts every time you change folder.
struct IndexingView: View {
    let client: FreeboxClient
    /// Pushed from the home screen, a sheet from the chips. See `StatsView.standalone`.
    var standalone = true

    @EnvironmentObject private var indexer: Indexer
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingRebuild = false
    @State private var knownCount = 0
    @State private var knownFolders = 0

    var body: some View {
        if standalone {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            nowSection
            troubleSection
            actionSection
            howSection
        }
        .alert("Index inaccessible", isPresented: Binding(
            get: { indexer.failure != nil },
            set: { if !$0 { indexer.failure = nil } }
        )) {
            Button("OK") { indexer.failure = nil }
        } message: {
            Text(indexer.failure ?? "")
        }
        // A quarter of an hour is a long time to hold a phone. The screen staying awake
        // while this screen is open and a pass is running is the plainest form of
        // "do not interrupt" there is — no entitlement, no new lifecycle, and the app
        // stays in the foreground where every existing guarantee already holds.
        .onChange(of: indexer.state.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            UIApplication.shared.isIdleTimerDisabled = indexer.state.isRunning
            knownFolders = (try? await IndexStore.shared.indexedFolderCount()) ?? 0
            knownCount = (try? await IndexStore.shared.fileCount()) ?? 0
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
        .navigationBarTitleDisplayMode(standalone ? .inline : .large)
        .toolbar {
            // The one gesture that throws away hours of reading does not share a rank with
            // the one made every week. It used to be a third row in the button section,
            // which is the screen saying the three gestures are worth the same.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmingRebuild = true } label: {
                        Label("Tout relire depuis zéro", systemImage: "trash")
                    }
                    .disabled(indexer.state.isRunning && !indexer.isStalled)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if standalone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    // MARK: Maintenant

    /// What is true right now, and nothing else.
    ///
    /// During a walk that is the folder under the needle. The rest of the time — which is
    /// almost all of the time — it is the last pass, told in `WalkSummary`'s own words. That
    /// report used to be shown for eight seconds in a floating card and then dropped, so the
    /// screen built to make the long boring work visible had nothing to say about it once it
    /// was done.
    @ViewBuilder
    private var nowSection: some View {
        Section {
            if indexer.state.isRunning, !indexer.isStalled, let progress = indexer.state.progress {
                walking(progress)
                lines(of: progress)
            } else if indexer.state.isPaused || indexer.isStalled {
                Label("En pause — reprend là où elle s'est arrêtée",
                      systemImage: "pause.circle.fill")
                    .foregroundStyle(Theme.warning)
                if let progress = indexer.state.progress { lines(of: progress) }
            } else if let pass = indexer.lastPass {
                settled(pass)
            } else if knownCount > 0 {
                // An index built before the report was kept, or one no complete pass has
                // closed yet. The count is all that is honestly known.
                Label("\(knownCount.formatted()) fichiers indexés",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    CageMark.Filled(height: 52, opacity: 0.8).foregroundStyle(.tint)
                    Text("Pas encore commencée")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        } header: {
            Text("Maintenant")
        }
    }

    @ViewBuilder
    private func walking(_ progress: Indexer.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func settled(_ pass: LastPass) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(pass.summary.headline, systemImage: "checkmark.circle")
                .font(.subheadline.weight(.medium))
            Text("Dernier passage complet : "
               + pass.finishedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(pass.summary.details, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Ten rows of counters were a dump of the `Progress` struct — per-pass and global mixed
    /// together, zeros spoken, and two of them saying what the bar above already said.
    /// `WalkSummary` already decides what deserves a line and in what order; using it live
    /// means the walk and its report speak with one voice.
    ///
    /// `indexedOverall` is deliberately left at zero: during a walk the grand total is both a
    /// duplicate of the resting state and a moving target.
    @ViewBuilder
    private func lines(of progress: Indexer.Progress) -> some View {
        ForEach(WalkSummary(foldersVisited: progress.foldersVisited,
                            foldersSkipped: progress.foldersSkipped,
                            datesRead: progress.datesRead,
                            dateless: progress.dateless,
                            adopted: progress.adopted,
                            unreadable: progress.unreadable).details, id: \.self) { line in
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: À surveiller

    /// Failures and refusals, at rest as well as in flight.
    ///
    /// They used to live only in `Progress`, so they were readable during the fifteen minutes
    /// of a walk and gone for the days that follow — backwards, since a share that went
    /// missing is worth knowing about precisely when nothing is running. Absent entirely when
    /// there is nothing to say: an empty "À surveiller" is an alarm that cried wolf.
    @ViewBuilder
    private var troubleSection: some View {
        if !trouble.isEmpty {
            Section {
                if trouble.unreachable > 0 {
                    problemLink("Dossiers inaccessibles", count: trouble.unreachable,
                                problems: trouble.problems.filter { $0.trouble == .folderUnreachable })
                }
                if trouble.unreadable > 0 {
                    problemLink("Fichiers illisibles", count: trouble.unreadable,
                                problems: trouble.problems.filter { $0.trouble == .fileUnreadable })
                }
                if trouble.excluded > 0 {
                    problemLink("Dossiers techniques exclus", count: trouble.excluded,
                                problems: trouble.problems.filter { $0.trouble == .folderExcluded },
                                footer: "Ces dossiers ne sont pas indexés : leurs fichiers "
                                      + "n'entrent ni dans la recherche, ni dans les "
                                      + "statistiques, ni dans les compteurs. Ils restent "
                                      + "consultables dans Parcourir.")
                }
            } header: {
                Text("À surveiller")
            }
        }
    }

    /// The live pass when there is one, the archived one otherwise. A finished pass keeps its
    /// `Progress` for the rest of the session, so the two agree; after a relaunch only the
    /// archive is left.
    private var trouble: Trouble {
        if indexer.state.isRunning || indexer.state.isPaused || indexer.isStalled,
           let progress = indexer.state.progress {
            return Trouble(unreachable: progress.unreachable, unreadable: progress.unreadable,
                           excluded: progress.foldersExcluded, problems: progress.problems)
        }
        if let pass = indexer.lastPass {
            return Trouble(unreachable: pass.unreachable, unreadable: pass.summary.unreadable,
                           excluded: pass.excluded, problems: pass.problems)
        }
        return Trouble()
    }

    private struct Trouble {
        var unreachable = 0
        var unreadable = 0
        var excluded = 0
        var problems: [IndexProblem] = []

        var isEmpty: Bool { unreachable == 0 && unreadable == 0 && excluded == 0 }
    }

    // MARK: Action

    private var actionSection: some View {
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
                    // Submitted on the tap and nowhere else: iOS only grants a
                    // continued task to work someone asked for.
                    ContinuedIndexing.submit(folders: knownFolders)
                }
                Button("Revérifier tous les dossiers",
                       systemImage: "arrow.clockwise") {
                    indexer.start(client: client, scope: .recheck)
                    ContinuedIndexing.submit(folders: knownFolders)
                }
            }
        }
    }

    // MARK: Comment ça marche

    /// Folded away, and four paragraphs rather than six plus a footer. What went: the
    /// paragraph comparing « Revérifier » and « Tout relire », which already lives in
    /// `rebuildWarning` at the only moment it is needed.
    private var howSection: some View {
        Section {
            DisclosureGroup("Comment ça marche") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keo parcourt le NAS et retient ce qu'il y trouve : les dossiers, "
                       + "les fichiers, leurs tailles, et la date de prise de vue de chaque "
                       + "photo et vidéo — lue dans les premiers kilo-octets, jamais en "
                       + "téléchargeant le fichier. C'est cet index qui permet le tri "
                       + "chronologique, la timeline, les totaux sur les dossiers, et leur "
                       + "ouverture instantanée.")
                    Text("Un fichier déjà lu n'est jamais relu, même après un arrêt : "
                       + "relancer reprend là où ça s'était arrêté.")
                    Text("Un dossier déjà indexé n'est réexaminé que s'il a changé : Keo "
                       + "compare sa date de modification, qui bouge dès qu'une photo y "
                       + "est ajoutée. Ajouter des photos ne demande donc jamais de tout "
                       + "réindexer — seules les nouvelles sont lues.")
                    Text("Sur iOS 26, un passage lancé ici continue même si tu verrouilles "
                       + "le téléphone, et une jauge du système l'affiche. Ailleurs, il se "
                       + "met en pause quand tu quittes l'app et reprend au retour. Tant que "
                       + "cet écran est ouvert, l'écran ne s'éteint pas.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
        }
    }

    /// Says what it costs, in the user's own numbers, before anything is thrown away.
    private var rebuildWarning: String {
        let dates = knownCount.formatted()
        return "Les \(dates) dates déjà lues seront effacées, puis chaque fichier sera relu "
             + "une par une sur le NAS. Compte plusieurs minutes par millier de photos.\n\n"
             + "À ne faire que si les dates affichées sont fausses. Pour simplement détecter "
             + "des photos ajoutées, « Revérifier tous les dossiers » suffit et ne relit rien."
    }

    /// Tappable only when there is something to show: the list is capped, so a very large
    /// failure keeps its honest count while detailing only the first entries.
    @ViewBuilder
    private func problemLink(_ label: String, count: Int, problems: [IndexProblem],
                             footer: String = ProblemList.retryFooter) -> some View {
        if problems.isEmpty {
            LabeledContent(label) {
                Text(count, format: .number).monospacedDigit().foregroundStyle(Theme.warning)
            }
        } else {
            NavigationLink {
                ProblemList(title: label, total: count, problems: problems, footer: footer)
            } label: {
                LabeledContent(label) {
                    Text(count, format: .number).monospacedDigit().foregroundStyle(Theme.warning)
                }
            }
        }
    }
}

/// Shown when a folder has more undated files than is reasonable to read on the fly.
/// The capsule both grid chips wear.
///
/// Only the contents differ between them; the chassis — padding, material, and above all the
/// tap target reaching 44 pt without the chip growing into the grid — was copied twice, which
/// is how the second copy loses the part that is easy to forget.
private struct GridChip<Content: View>: View {
    let open: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) { content }
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

struct UnindexedChip: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        GridChip(open: open) {
            Image(systemName: "calendar.badge.exclamationmark")
            Text(Undoer.count(count, "élément pas encore lu", "éléments pas encore lus"))
                .fontDesign(.rounded)
                .font(.caption.weight(.medium))
        }
    }
}

/// The global pass, visible from wherever you are browsing.
struct IndexingChip: View {
    let fraction: Double
    let pending: Int
    let open: () -> Void

    var body: some View {
        GridChip(open: open) {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text("Indexation · " + Undoer.count(pending, "restante", "restantes"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}


/// The detail behind a failure count.
private struct ProblemList: View {
    /// Ce que dit une liste d'échecs. Une liste d'exclusions dit autre chose, et prétendre
    /// que des dossiers volontairement ignorés « seront réessayés » serait un mensonge.
    static let retryFooter = "Ces entrées ne sont pas perdues : elles restent à lire et "
                           + "seront réessayées au prochain passage."

    let title: String
    let total: Int
    let problems: [IndexProblem]
    var footer = Self.retryFooter

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
                            .foregroundStyle(Theme.warning)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                if total > problems.count {
                    Text("\(total.formatted()) au total, les \(problems.count) premiers sont "
                       + "listés ici.\n\n" + footer)
                } else {
                    Text(footer)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
