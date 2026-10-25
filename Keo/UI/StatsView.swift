import Charts
import SwiftUI

/// What the index knows about the library — and, just as loudly, what it does not.
///
/// Everything here is computed on the local index, never on the box, so the screen opens
/// instantly and works with the NAS switched off. The price is that a folder never walked is
/// invisible; the banner at the top says so rather than letting a half-built index pass for
/// the whole library. Every figure is a tap into a grid or a folder: a number nobody can go
/// and check is a number nobody should believe.
struct StatsView: View {
    let client: FreeboxClient
    /// Pushed from the home screen, presented as a sheet from the chips that raise it in
    /// context. A pushed screen brings its own stack and its own way out; a sheet needs both.
    var standalone = true

    @Environment(\.dismiss) private var dismiss

    /// Read once when the screen opens: a dozen scans of the index are cheap, but not cheap
    /// enough to redo on every redraw.
    @State private var stats: LibraryStats?
    @State private var destination: BrowserSource?
    @State private var showingIndexing = false

    var body: some View {
        if standalone {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
                if let stats {
                    if stats.isPartial { coverage(stats) }
                    chronology(stats)
                    weight(stats)
                    duplicates(stats)
                    biggest(stats)
                    busiest(stats)
                    onThisDay(stats)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Statistiques")
            .navigationBarTitleDisplayMode(standalone ? .inline : .large)
            .navigationDestination(item: $destination) { source in
                BrowserView(client: client, source: source)
            }
            .toolbar {
                if standalone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showingIndexing) { IndexingView(client: client) }
            .task {
                stats = try? await IndexStore.shared.statistics(under: FreeboxClient.rootPath)
            }
    }

    // MARK: Coverage

    @ViewBuilder
    private func coverage(_ stats: LibraryStats) -> some View {
        Section {
            Label(stats.coverage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Continuer l'indexation…", systemImage: "square.stack.3d.up") {
                showingIndexing = true
            }
        } footer: {
            Text("Tout ce qui suit ne porte que sur cette part de la bibliothèque. "
               + "Les dossiers jamais parcourus n'y comptent pour rien — ni en nombre, "
               + "ni en poids.")
        }
    }

    // MARK: Chronologie

    @ViewBuilder
    private func chronology(_ stats: LibraryStats) -> some View {
        Section {
            if stats.years.isEmpty {
                Text("Aucune date de prise de vue connue pour l'instant.")
                    .foregroundStyle(.secondary)
            } else {
                chart(stats.years)
                ForEach(stats.years.reversed()) { tally in
                    row { open(year: tally.year) } label: {
                        LabeledContent(String(tally.year)) {
                            Text(detail(tally)).monospacedDigit()
                        }
                    }
                }
            }

            if let first = stats.firstCapture {
                row { open(day: first, title: label(first)) } label: {
                    LabeledContent("Première photo") { Text(HumanDate.origin(first)) }
                }
            }

            // The two numbers that must never be added up: one is about the files, the
            // other about the index. Summing them would invent a fact about neither.
            if stats.datelessRead > 0 {
                row { openDateless() } label: {
                    LabeledContent("Sans date de prise de vue") {
                        Text(stats.datelessRead, format: .number).monospacedDigit()
                    }
                }
            }
            if stats.datelessUnread > 0 {
                row { showingIndexing = true } label: {
                    LabeledContent("Pas encore lues") {
                        Text(stats.datelessUnread, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Chronologie")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let gap = stats.gap { Text(gap.label) }
                Text("« Sans date » dit quelque chose des fichiers : ils ne portent aucune "
                   + "date de prise de vue. « Pas encore lues » dit quelque chose de l'index : "
                   + "ces photos en ont peut-être une, personne n'a encore regardé. "
                   + "Les additionner ne voudrait rien dire.")
            }
        }
    }

    private func chart(_ years: [YearTally]) -> some View {
        Chart(years) { tally in
            BarMark(x: .value("Année", tally.year), y: .value("Nombre", tally.photos))
                .foregroundStyle(by: .value("Type", "Photos"))
            BarMark(x: .value("Année", tally.year), y: .value("Nombre", tally.videos))
                .foregroundStyle(by: .value("Type", "Vidéos"))
        }
        .chartXAxis {
            // A year is a number, not a quantity: grouping separators would print "2 024".
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisTick()
                AxisValueLabel {
                    if let year = value.as(Int.self) { Text(String(year)) }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { point in
                        guard let plot = proxy.plotFrame,
                              let tapped: Double = proxy.value(atX: point.x
                                                               - geometry[plot].origin.x),
                              let closest = years.min(by: {
                                  abs(Double($0.year) - tapped) < abs(Double($1.year) - tapped)
                              })
                        else { return }
                        open(year: closest.year)
                    }
            }
        }
        .frame(height: 190)
        .padding(.vertical, 6)
    }

    private func detail(_ tally: YearTally) -> String {
        guard tally.videos > 0 else { return "\(tally.photos.formatted()) photos" }
        guard tally.photos > 0 else { return "\(tally.videos.formatted()) vidéos" }
        return "\(tally.photos.formatted()) photos · \(tally.videos.formatted()) vidéos"
    }

    // MARK: Poids

    @ViewBuilder
    private func weight(_ stats: LibraryStats) -> some View {
        if !stats.subtrees.isEmpty {
            let heaviest = stats.subtrees.map(\.bytes).max() ?? 0
            Section {
                ForEach(stats.subtrees) { subtree in
                    row { destination = .folder(path: subtree.path, title: subtree.name) } label: {
                        bar(subtree, heaviest: heaviest)
                    }
                }
            } header: {
                Text("Poids")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let sentence = Statistics.kindSentence(stats.kinds) { Text(sentence) }
                    Text("Les barres additionnent les dossiers déjà pesés ; la phrase "
                       + "ci-dessus additionne tout ce qu'un listing a montré, lu ou non. "
                       + "Les deux sont vraies et ne tombent pas sur le même octet.")
                }
            }
        }
    }

    private func bar(_ subtree: Subtree, heaviest: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(subtree.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                if subtree.media > 0 {
                    Text("\(subtree.media.formatted()) éléments")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3).fill(.tint)
                        .frame(width: geometry.size.width * subtree.fraction(of: heaviest))
                }
            }
            .frame(height: 6)
            Text(subtree.weight)
                .font(.caption.monospacedDigit())
                .foregroundStyle(subtree.unweighed > 0 ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Doublons probables

    @ViewBuilder
    private func duplicates(_ stats: LibraryStats) -> some View {
        if stats.duplicates.groups > 0 {
            Section {
                ForEach(stats.worstDuplicates) { group in
                    row { open(group: group) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.subheadline).lineLimit(1)
                                .truncationMode(.middle)
                            Text(group.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Doublons probables (même nom, même taille)")
            } footer: {
                Text("\(stats.duplicates.groups.formatted()) groupes, "
                   + "\(stats.duplicates.extraFiles.formatted()) fichiers en trop, "
                   + "\(stats.duplicates.recoverableBytes.formatted(.byteCount(style: .file))) "
                   + "récupérables.\n\nMême nom et même taille, ce n'est pas une empreinte : "
                   + "deux photos différentes peuvent coïncider. À vérifier soi-même avant de "
                   + "supprimer quoi que ce soit sur la box — Keo, lui, n'y touchera jamais.")
            }
        }
    }

    // MARK: Plus gros fichiers

    @ViewBuilder
    private func biggest(_ stats: LibraryStats) -> some View {
        if !stats.biggest.isEmpty {
            Section("Plus gros fichiers") {
                ForEach(stats.biggest) { item in
                    row { destination = BrowserSource.parent(of: item) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline).lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.size.formatted(.byteCount(style: .file))
                               + " · " + (item.path as NSString).deletingLastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
        }
    }

    // MARK: Jours les plus photographiés

    @ViewBuilder
    private func busiest(_ stats: LibraryStats) -> some View {
        if !stats.busiestDays.isEmpty {
            Section("Jours les plus photographiés") {
                ForEach(stats.busiestDays) { day in
                    row { open(day: day.day, title: label(day.day)) } label: {
                        LabeledContent(label(day.day)) {
                            Text(day.count, format: .number).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func label(_ day: Date) -> String {
        day.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: Ce jour-là

    @ViewBuilder
    private func onThisDay(_ stats: LibraryStats) -> some View {
        if !stats.onThisDay.isEmpty {
            Section {
                row { destination = .results(title: "Ce jour-là", items: stats.onThisDay) } label: {
                    LabeledContent("Les années précédentes") {
                        Text(stats.onThisDay.count, format: .number).monospacedDigit()
                    }
                }
            } header: {
                Text("Ce jour-là")
            } footer: {
                Text("Photos et vidéos prises un \(Date().formatted(.dateTime.day().month(.wide))), "
                   + "les autres années.")
            }
        }
    }

    // MARK: Navigation

    /// Rows look like navigation because they are: the destination of several of them has to
    /// be fetched first, which `NavigationLink(value:)` cannot express.
    private func row(_ open: @escaping () -> Void,
                     @ViewBuilder label: () -> some View) -> some View {
        Button(action: open) {
            HStack {
                label()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(year: Int) {
        open(search: SearchQuery(period: .year(year)), title: String(year))
    }

    private func open(day: Date, title: String) {
        open(search: SearchQuery(period: .between(day, day)), title: title)
    }

    private func open(search query: SearchQuery, title: String) {
        Task {
            let found = (try? await IndexStore.shared.search(query, limit: 2_000)) ?? []
            destination = .results(title: title, items: found)
        }
    }

    private func openDateless() {
        Task {
            let found = (try? await IndexStore.shared.datelessFiles()) ?? []
            destination = .results(title: "Sans date", items: found)
        }
    }

    private func open(group: DuplicateGroup) {
        Task {
            let found = (try? await IndexStore.shared.copies(of: group)) ?? []
            destination = .results(title: group.name, items: found)
        }
    }
}
