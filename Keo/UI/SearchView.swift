import SwiftUI

/// Search over the local index — never the box.
///
/// That is the whole design: it answers in milliseconds, it works with the NAS switched off,
/// and in exchange it can only find what has been indexed. The view says so out loud instead
/// of letting an un-walked folder look like "no results".
struct SearchView: View {
    let client: FreeboxClient

    @State private var query = SearchQuery()
    @State private var results: [Item] = []
    @State private var searched = SearchQuery()
    @State private var years: [Int] = []
    @State private var indexedFolders = 0
    @State private var showingIndexing = false

    private var resultsTitle: String {
        results.count == 1 ? "1 résultat" : "\(results.count) résultats"
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            content
        }
        .navigationTitle("Recherche")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.text,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Nom de fichier ou de dossier")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // One query per settled keystroke: typing eight letters runs one search, not eight.
        .task(id: query) { await run() }
        .task { await loadContext() }
        .sheet(isPresented: $showingIndexing) { IndexingView(client: client) }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(spacing: 8) {
            Picker("Type", selection: $query.kinds) {
                ForEach(SearchQuery.Kinds.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Menu {
                    Button("Toutes les années") { query.year = nil }
                    ForEach(years, id: \.self) { year in
                        Button(String(year)) { query.year = year }
                    }
                } label: {
                    Chip(label: query.year.map(String.init) ?? "Période",
                         icon: "calendar", on: query.year != nil)
                }
                // Folders have no capture date, so a period can only ever narrow to files.
                .disabled(years.isEmpty)

                Button {
                    query.favouritesOnly.toggle()
                } label: {
                    Chip(label: "Favoris", icon: "heart", on: query.favouritesOnly)
                }
                .buttonStyle(.plain)

                Spacer()

                if !query.isEmpty {
                    Button("Effacer") { query = SearchQuery() }
                        .font(.footnote.weight(.medium))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                Label("Aucun résultat", systemImage: "magnifyingglass")
            } description: {
                Text(scope)
            } actions: {
                indexingButton
            }
        } else {
            BrowserView(client: client, source: .results(title: resultsTitle, items: results))
        }
    }

    private var scope: String {
        indexedFolders == 0
            ? "Rien n'est encore indexé : lancez une analyse pour pouvoir chercher."
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
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}
