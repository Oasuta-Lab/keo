import SwiftUI

/// Search over the local index — never the box.
///
/// That is the whole design: it answers in milliseconds, it works with the NAS switched off,
/// and in exchange it can only find what has been indexed. The view says so out loud instead
/// of letting an un-walked folder look like "no results".
struct SearchView: View {
    let client: FreeboxClient
    /// Set by a widget tap. Consumed once, then cleared, so going back to the tab
    /// later does not silently re-apply yesterday's filter.
    @Binding var seed: SearchQuery?

    @State private var query = SearchQuery()
    @State private var results: [Item] = []
    @State private var searched = SearchQuery()
    @State private var years: [Int] = []
    @State private var indexedFolders = 0
    @State private var showingIndexing = false
    @State private var pickingDates = false
    @State private var from = Date()
    @State private var to = Date()

    private var resultsTitle: String {
        results.count == 1 ? "1 résultat" : "\(results.count) résultats"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hidden until there is something to filter. At full weight above an empty
            // screen they read as a form to fill in before being allowed to search.
            if !query.isEmpty || !results.isEmpty {
                filters
                Divider()
            }
            content
        }
        .navigationTitle("Recherche")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.text,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Nom de fichier, de dossier, ou note")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // One query per settled keystroke: typing eight letters runs one search, not eight.
        .task(id: query) { await run() }
        .task { await loadContext() }
        .onChange(of: seed) { _, now in
            guard let now else { return }
            query = now
            seed = nil
        }
        .sheet(isPresented: $showingIndexing) { IndexingView(client: client) }
        .sheet(isPresented: $pickingDates) { dateRangeSheet }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(spacing: 8) {
            Picker("Type", selection: $query.kinds) {
                ForEach(SearchQuery.Kinds.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // The row scrolls instead of squeezing. On a 12 Pro the four controls did not fit,
            // and SwiftUI resolved it by wrapping inside the capsules — « Fa-voris », « Note s ».
            // « Effacer » stays outside the scroller so it cannot drift off the edge.
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                Menu {
                    Button("Toutes les périodes") { query.period = .any }
                    Button("Entre deux dates…") { pickingDates = true }
                    if !years.isEmpty {
                        Section("Année") {
                            ForEach(years, id: \.self) { year in
                                Button(String(year)) { query.period = .year(year) }
                            }
                        }
                    }
                } label: {
                    Chip(label: Self.label(for: query.period), icon: "calendar",
                         on: query.period.isSet)
                }

                Button {
                    query.favouritesOnly.toggle()
                } label: {
                    Chip(label: "Favoris", icon: "heart", on: query.favouritesOnly)
                }
                .buttonStyle(.plain)

                Button {
                    query.notedOnly.toggle()
                } label: {
                    Chip(label: "Notes", icon: "text.quote", on: query.notedOnly)
                }
                .buttonStyle(.plain)
                    }
                    // The capsules would otherwise be clipped by the scroller's bounds.
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)

                if !query.isEmpty {
                    Button("Effacer") { query = SearchQuery() }
                        .font(.footnote.weight(.medium))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("ddMMyy")
        return formatter
    }()

    private static func label(for period: SearchQuery.Period) -> String {
        switch period {
        case .any: return "Période"
        case .year(let year): return String(year)
        case .between(let from, let to):
            return "\(short.string(from: min(from, to))) – \(short.string(from: max(from, to)))"
        }
    }

    private var dateRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Du", selection: $from, displayedComponents: .date)
                DatePicker("Au", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("Entre deux dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { pickingDates = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer") {
                        query.period = .between(from, to)
                        pickingDates = false
                    }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        if query.isEmpty {
            ContentUnavailableView {
                Label("Rechercher", systemImage: "magnifyingglass")
            } description: {
                Text(scope)
            } actions: {
                indexingButton
            }
        } else if results.isEmpty, query == searched {
            ContentUnavailableView {
                Label("Rien trouvé", systemImage: "magnifyingglass")
            } description: {
                Text(scope)
            } actions: {
                indexingButton
            }
        } else {
            BrowserView(client: client,
                        source: .results(title: resultsTitle, items: results),
                        root: true)
        }
    }

    private var scope: String {
        indexedFolders == 0
            ? "Rien n'est encore indexé : lance une analyse pour pouvoir chercher."
            : "La recherche porte sur les \(indexedFolders) dossiers déjà indexés. "
              + "Un dossier jamais parcouru n'apparaîtra pas."
    }

    @ViewBuilder
    private var indexingButton: some View {
        Button("Analyser le NAS") { showingIndexing = true }
            .buttonStyle(.bordered)
    }

    // MARK: Work

    private func run() async {
        let asked = query
        guard !asked.isEmpty else {
            results = []
            searched = asked
            return
        }
        // Settle first: the index is fast, the keyboard is faster.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let found = (try? await IndexStore.shared.search(asked)) ?? []
        guard !Task.isCancelled else { return }
        results = found
        searched = asked
    }

    private func loadContext() async {
        years = (try? await IndexStore.shared.indexedYears()) ?? []
        indexedFolders = (try? await IndexStore.shared.indexedFolderCount()) ?? 0
    }
}

private struct Chip: View {
    let label: String
    let icon: String
    let on: Bool

    var body: some View {
        Label(label, systemImage: icon)
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .foregroundStyle(on ? AnyShapeStyle(Color("OnAccent")) : AnyShapeStyle(.primary))
    }
}
