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
    @State private var memoryPage = 0
    @State private var showingIndexing = false
    @State private var disk: (total: Int64, free: Int64, seen: Date)?

    /// The page on screen. Clamped, because the list is rebuilt whenever the index moves and
    /// a stale page number would read past the end.
    private var shown: (year: Int, items: [Item])? {
        let years = memoriesByYear
        guard !years.isEmpty else { return nil }
        return years[min(memoryPage, years.count - 1)]
    }

    private func subtitle(for group: (year: Int, items: [Item])) -> String {
        let count = Undoer.count(group.items.count, "photo", "photos")
        guard let day = group.items.first?.captureDate else { return count }
        return "\(HumanDate.story(day)) · \(count)"
    }

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
                header
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
        // Drawn in the content rather than as a navigation title: a large title renders on
        // its own line below the bar, so the logo could only ever sit above the word, never
        // beside it.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(item: $destination) { source in
            BrowserView(client: client, source: source)
        }
        .modifier(PushTargets(client: client, declare: true))
        .sheet(isPresented: $showingIndexing) { IndexingView(client: client) }
        .task { await load() }
        .onChange(of: undoer.revision) { _, _ in Task { await load() } }
        .onChange(of: indexer.state.isRunning) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tight, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Keo").font(.largeTitle.bold())
                Text(Self.today)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let text = formatter.string(from: Date())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Ce jour-là

    @ViewBuilder
    private var memories: some View {
        if !memoriesByYear.isEmpty {
            // No header: the card says « CE JOUR-LÀ » itself, over the photo, and a title
            // above a title is the kind of stacking that makes a screen feel like a form.
            // Only the photograph slides. The caption and the dots are chrome over the
            // carousel, not passengers in it — riding along, they read as part of the image
            // and the eye has to re-find them on every swipe.
            ZStack(alignment: .bottomLeading) {
                TabView(selection: $memoryPage) {
                    ForEach(Array(memoriesByYear.enumerated()), id: \.element.year) { page, group in
                        Color.clear
                            .overlay {
                                if let cover = group.items.first {
                                    Thumb(item: cover, client: client, selected: nil,
                                          lookahead: [])
                                }
                            }
                            .clipped()
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                LinearGradient(colors: [.black.opacity(Theme.Scrim.caption), .clear],
                               startPoint: .bottom, endPoint: .center)
                    .allowsHitTesting(false)

                if let shown {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CE JOUR-LÀ")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(HumanDate.yearsAgo(from: shown.items.first?.captureDate ?? Date()))
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text(subtitle(for: shown))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(16)
                    .contentTransition(.opacity)
                    .allowsHitTesting(false)
                }

                if memoriesByYear.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(memoriesByYear.indices, id: \.self) { index in
                            Circle()
                                .fill(.white.opacity(index == memoryPage ? 0.95 : 0.4))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(Theme.Scrim.chip), in: Capsule())
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Année \(memoryPage + 1) sur \(memoriesByYear.count)")
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            // The overlays let taps through, so this opens the year on screen while the
            // carousel keeps its own swipe.
            .contentShape(Rectangle())
            .onTapGesture {
                guard let shown else { return }
                destination = .results(title: "Ce jour-là en \(shown.year)", items: shown.items)
            }
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
                                FolderCard(folder: folder, stats: pinStats[folder.path],
                                           cover: pinCovers[folder.path], client: client,
                                           width: 140)
                            }
                            .buttonStyle(.plain)
                            // Pinning happens in Parcourir by long press; unpinning had no
                            // gesture at all from the shelf the pins actually live on.
                            .contextMenu {
                                Button("Désépingler", systemImage: "pin.slash",
                                       role: .destructive) {
                                    unpin(folder)
                                }
                            }
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
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tight,
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
                storage
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
                        in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        }
    }

    /// The gauge needs a capacity, and the capacity lives on the box. Keo is LAN-only, so
    /// fetching it on sight would leave the bar blank every time the owner is out — which is
    /// most of the day. It is therefore read when the phone is home and remembered: the box
    /// does not sleep, the phone leaves.
    /// Under a tenth left. Below this the gauge and its glyph both change.
    private var nearlyFull: Bool {
        guard let disk, disk.total > 0 else { return false }
        return Double(disk.free) / Double(disk.total) < 0.1
    }

    @ViewBuilder
    private var storage: some View {
        if let disk {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // The gauge turning amber is not enough on its own: the glyph changes too,
                    // so a disk running out still reads without relying on colour.
                    Image(systemName: nearlyFull ? "internaldrive.badge.xmark" : "internaldrive")
                        .foregroundStyle(nearlyFull ? AnyShapeStyle(Theme.warning)
                                                    : AnyShapeStyle(.tint))
                        .frame(width: 28)
                    Text("Stockage")
                    Spacer(minLength: 8)
                    Text((disk.total - disk.free).formatted(.byteCount(style: .file))
                       + " sur " + disk.total.formatted(.byteCount(style: .file)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: Double(disk.total - disk.free), total: Double(disk.total))
                    .tint(nearlyFull ? Theme.warning : .accentColor)
                    .padding(.leading, 28)
                Text("Dont \(weightLabel) lus par Keo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            LibraryRow(icon: "internaldrive", title: "Poids lu", detail: weightLabel,
                       chevron: false)
        }
    }

    /// « au moins » when some stamped folder has no weight: the total is a floor, not a
    /// figure, and the index says which rather than quietly rounding up.
    private var weightLabel: String {
        guard let summary, summary.bytes > 0 else { return "—" }
        let size = summary.bytes.formatted(.byteCount(style: .file))
        return summary.unweighed > 0 ? "au moins \(size)" : size
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

    private func unpin(_ folder: Item) {
        Task {
            try? await IndexStore.shared.setShortcut(folder, false)
            await load()
            undoer.record("« \(folder.name) » désépinglé") {
                try? await IndexStore.shared.setShortcut(folder, true)
            }
        }
    }

    private func load() async {
        summary = try? await IndexStore.shared.homeSummary()
        pins = (try? await IndexStore.shared.shortcuts()) ?? []
        let paths = pins.map(\.path)
        pinStats = (try? await IndexStore.shared.stats(for: paths)) ?? [:]
        pinCovers = (try? await IndexStore.shared.covers(for: paths)) ?? [:]
        recent = (try? await IndexStore.shared.recentMedia(under: FreeboxClient.rootPath,
                                                           limit: 12)) ?? []
        disk = try? await IndexStore.shared.capacity()

        // Refreshed in the background, and only when the box answers. A failure here is not
        // worth a word on screen: the remembered figure stays, and it is still true.
        if let fresh = try? await client.storage() {
            try? await IndexStore.shared.rememberCapacity(total: fresh.total, free: fresh.free)
            disk = try? await IndexStore.shared.capacity()
        }
    }
}

// MARK: - Pieces

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
                    .foregroundStyle(warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
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
/// the mark is allowed — never on a screen that has photos on it, where the photos win.
private struct WelcomeCard: View {
    let reachable: Bool
    let start: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            CageMark.Filled(height: 64).foregroundStyle(.tint)
            Text("Bienvenue dans Keo").font(.title3.bold())
            Text("Keo n'a encore rien vu de ta bibliothèque. Une première lecture construit "
               + "son index : les vraies dates de prise de vue, la timeline, la recherche — "
               + "tout ce qui marche ensuite même sans la box.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if reachable {
                Button("Lancer la première lecture", action: start)
                    // The label colour SwiftUI picks for a prominent button assumes a
                    // dark fill. Keo's accent is a pale peach in dark mode, where white
                    // on it falls to 2.1:1 — `OnAccent` flips with the appearance.
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color("OnAccent"))
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
                    in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}
