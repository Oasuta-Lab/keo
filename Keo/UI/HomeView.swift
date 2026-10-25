import SwiftUI

/// Where the app speaks first.
///
/// Opening Keo used to drop you into a folder listing titled with a hostname. That listing is
/// the best folder browser a Freebox will ever have — fifteen years of someone's own
/// organisation — but it was never a home. It stays, one tab over; this is the room that
/// answers "what is in here, and what do I want right now".
///
/// Everything below comes from the local index. The box can be off all day and this screen
/// never blinks — which is the point, since the NAS is on the home network and the phone is
/// not, most of the day.
struct HomeView: View {
    let client: FreeboxClient
    let boxName: String

    @EnvironmentObject private var indexer: Indexer
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var undoer: Undoer

    @State private var summary: HomeSummary?
    @State private var pins: [Item] = []
    @State private var pinStats: [String: FolderStats] = [:]
    @State private var pinCovers: [String: Item] = [:]
    @State private var recent: [Item] = []
    @State private var destination: BrowserSource?
    @State private var showingIndexing = false

    private var memoriesByYear: [(year: Int, items: [Item])] {
        guard let summary else { return [] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: summary.memories) { item in
            item.captureDate.map { calendar.component(.year, from: $0) } ?? 0
        }
        return grouped.filter { $0.key > 0 }
            .sorted { $0.key > $1.key }
            .map { (year: $0.key, items: $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let summary, summary.isEmpty {
                    WelcomeCard(reachable: store.client != nil) {
                        indexer.start(client: client)
                    }
                } else {
                    memories
                    pinned
                    latest
                }
                library
                VStack(spacing: 6) {
                    SyncFootnote()
                    BuildStampLabel()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Keo")
        .modifier(DaySubtitle())
        .navigationDestination(item: $destination) { source in
            BrowserView(client: client, source: source)
        }
        .navigationDestination(for: BrowserSource.self) { source in
            BrowserView(client: client, source: source)
        }
        .sheet(isPresented: $showingIndexing) { IndexingView(client: client) }
        .task { await load() }
        .onChange(of: undoer.revision) { _, _ in Task { await load() } }
        .onChange(of: indexer.state.isRunning) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    // MARK: Ce jour-là

    @ViewBuilder
    private var memories: some View {
        if !memoriesByYear.isEmpty {
            // No header: the card says « CE JOUR-LÀ » itself, over the photo, and a title
            // above a title is the kind of stacking that makes a screen feel like a form.
            TabView {
                ForEach(memoriesByYear, id: \.year) { group in
                    MemoryCard(group: group, client: client) {
                        destination = .results(
                            title: "Ce jour-là en \(group.year)", items: group.items)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: memoriesByYear.count > 1 ? .automatic : .never))
            .aspectRatio(4 / 3, contentMode: .fit)
        }
    }

    // MARK: Épinglés

    @ViewBuilder
    private var pinned: some View {
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Épinglés").font(.title3.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(pins) { folder in
                            NavigationLink(value: BrowserSource.folder(folder)) {
                                PinCard(folder: folder, stats: pinStats[folder.path],
                                        cover: pinCovers[folder.path], client: client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        } else if summary?.isEmpty == false {
            Text("Épingle un dossier — appui long dans Parcourir — pour le garder ici.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Dernières photos

    @ViewBuilder
    private var latest: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dernières photos").font(.title3.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 3) {
                        ForEach(recent) { item in
                            Button {
                                destination = .results(title: "Dernières photos", items: recent)
                            } label: {
                                Thumb(item: item, client: client, selected: nil, lookahead: [])
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8,
                                                                style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Chronologie

    // MARK: Bibliothèque

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bibliothèque").font(.title3.bold())
            VStack(spacing: 0) {
                // The machinery used to be in the sort menu of every folder. It belongs in
                // one room, where its state is visible at a glance instead of being
                // rediscovered — that is the difference between a gallery and a console.
                NavigationLink {
                    IndexingView(client: client, standalone: false)
                } label: {
                    LibraryRow(icon: "square.stack.3d.up", title: "Indexation",
                               detail: indexingState, warning: summary?.isPartial == true)
                }
                Divider().padding(.leading, 52)
                NavigationLink {
                    StatsView(client: client, standalone: false)
                } label: {
                    LibraryRow(icon: "chart.bar", title: "Statistiques", detail: nil)
                }
                Divider().padding(.leading, 52)
                Menu {
                    Button("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right",
                           role: .destructive) { store.signOut() }
                } label: {
                    LibraryRow(icon: "externaldrive.connected.to.line.below",
                               title: "Freebox", detail: boxName, chevron: false)
                }
            }
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var indexingState: String {
        if indexer.state.isRunning, !indexer.isStalled { return "En cours…" }
        guard let summary else { return "…" }
        if summary.isEmpty { return "Pas encore commencée" }
        if summary.indexedFolders < summary.knownFolders {
            return "\(summary.indexedFolders.formatted()) dossiers sur "
                 + "\(summary.knownFolders.formatted())"
        }
        if summary.unreadFiles > 0 {
            return "\(summary.unreadFiles.formatted()) fichiers à lire"
        }
        return "À jour · \(summary.fileCount.formatted()) fichiers"
    }

    // MARK: Work

    private func load() async {
        summary = try? await IndexStore.shared.homeSummary()
        pins = (try? await IndexStore.shared.shortcuts()) ?? []
        let paths = pins.map(\.path)
        pinStats = (try? await IndexStore.shared.stats(for: paths)) ?? [:]
        pinCovers = (try? await IndexStore.shared.covers(for: paths)) ?? [:]
        recent = (try? await IndexStore.shared.recentMedia(under: FreeboxClient.rootPath,
                                                           limit: 12)) ?? []
    }
}

// MARK: - Pieces

/// « Samedi 25 octobre » under the title. On iOS 26 it is a real navigation subtitle; below
/// that the date would have to be faked as content, which looks worse than not having it.
private struct DaySubtitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(Self.today)
        } else {
            content
        }
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let text = formatter.string(from: Date())
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One year of this day, under its own photo. The text sits on a gradient of the photo
/// itself — the owner's colour, with no extraction code anywhere.
private struct MemoryCard: View {
    let group: (year: Int, items: [Item])
    let client: FreeboxClient
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .overlay {
                        if let cover = group.items.first {
                            Thumb(item: cover, client: client, selected: nil, lookahead: [])
                        }
                    }
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.75), .clear],
                               startPoint: .bottom, endPoint: .center)

                VStack(alignment: .leading, spacing: 3) {
                    Text("CE JOUR-LÀ")
                        .font(.caption2.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(HumanDate.yearsAgo(from: group.items.first?.captureDate ?? Date()))
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let count = Undoer.count(group.items.count, "photo", "photos")
        guard let day = group.items.first?.captureDate else { return count }
        return "\(HumanDate.story(day)) · \(count)"
    }
}

private struct PinCard: View {
    let folder: Item
    let stats: FolderStats?
    let cover: Item?
    let client: FreeboxClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let cover {
                        Thumb(item: cover, client: client, selected: nil, lookahead: [])
                    } else {
                        Image(systemName: "folder")
                            .font(.title)
                            .foregroundStyle(.tint)
                    }
                }
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(folder.name).font(.subheadline).lineLimit(1)
            // Omitted rather than zeroed: on a folder the index has not finished, the count
            // is genuinely unknown, and "0" would read as "this folder is empty".
            if let count = stats?.mediaCount {
                Text(Undoer.count(count, "photo", "photos"))
                    .font(.caption2)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140)
    }
}

private struct LibraryRow: View {
    let icon: String
    let title: String
    var detail: String?
    var warning = false
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// The first launch, when the app has nothing of the owner's to show. One of the three places
/// the mascot is allowed — never on a screen that has photos on it, where the photos win.
private struct WelcomeCard: View {
    let reachable: Bool
    let start: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Mascot(height: 96)
            Text("Bienvenue dans Keo").font(.title3.bold())
            Text("Keo n'a encore rien vu de ta bibliothèque. Une première lecture construit "
               + "son index : les vraies dates de prise de vue, la timeline, la recherche — "
               + "tout ce qui marche ensuite même sans la box.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if reachable {
                Button("Lancer la première lecture", action: start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                // Absence of the box is Tuesday, not a failure. No error styling.
                Text("La Freebox est injoignable — Keo lira ta bibliothèque dès qu'il la "
                   + "retrouvera.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
