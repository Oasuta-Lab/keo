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
    /// Content that moves on its own has to be something the reader can opt out of.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var summary: HomeSummary?
    @State private var pins: [Item] = []
    @State private var pinStats: [String: FolderStats] = [:]
    @State private var pinCovers: [String: [Item]] = [:]
    @State private var recent: [Item] = []
    /// Ce qui est arrivé depuis que Keo regarde. Vide tant que rien n'est arrivé, et alors
    /// l'étagère ne s'affiche pas — une section vide sur un accueil est une promesse non tenue.
    @State private var arrivals: [Item] = []
    @State private var destination: BrowserSource?
    @State private var memoryPage = 0
    /// Advances once per auto-turn, and indexes into each year's photos — so a year that
    /// comes back round does not come back with the same picture.
    @State private var rotation = 0
    /// When the memory on screen took its turn. The progress bar is read from the clock
    /// rather than animated: an animation that a swipe interrupts has to be unwound before it
    /// can restart, and that unwinding is exactly what read as the bar being slow to resume.
    @State private var turnStarted = Date()

    /// How long a memory holds the card.
    private static let turnEvery: TimeInterval = 6

    /// How far through its turn the memory on screen is, from 0 to 1.
    static func turnFraction(since start: Date, now: Date) -> CGFloat {
        let elapsed = now.timeIntervalSince(start)
        return min(max(elapsed / turnEvery, 0), 1)
    }

    /// Width of a row of `count` six-point dots spaced five apart.
    private static func dotsWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * 6 + CGFloat(max(0, count - 1)) * 5
    }
    @State private var showingIndexing = false
    /// Signing out drops a key that iCloud shares with the owner's other devices, so it is
    /// not a local undoable thing.
    @State private var signingOut = false
    @State private var disk: (total: Int64, free: Int64, seen: Date)?

    /// The page on screen. Clamped, because the list is rebuilt whenever the index moves and
    /// a stale page number would read past the end.
    private var shown: (year: Int, items: [Item])? {
        let years = memoriesByYear
        guard !years.isEmpty else { return nil }
        return years[min(memoryPage, years.count - 1)]
    }

    private func subtitle(for group: (year: Int, items: [Item])) -> String {
        let count = Undoer.count(group.items.count, "élément", "éléments")
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
                    arrived
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
        // Centred, like the rest of the app's questions — see `CollectionsView`.
        .alert("Se déconnecter de la Freebox ?", isPresented: $signingOut) {
            Button("Se déconnecter", role: .destructive) { store.signOut() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'autorisation est partagée par iCloud : tes autres appareils la perdent "
               + "aussi, et il faudra réappuyer sur ✓ sur la face avant de la Freebox.")
        }
        .task { await load() }
        .onChange(of: undoer.revision) { _, _ in Task { await load() } }
        .onChange(of: indexer.state.isRunning) { _, _ in Task { await load() } }
        .refreshable { await load() }
    }

    /// The date rides above the name as an eyebrow, in the same treatment « CE JOUR-LÀ » wears
    /// on the memory card below — so the screen opens on one typographic idea instead of two.
    ///
    /// No tile: the icon is already on the phone's home screen, one gesture away, and repeating
    /// it here is a habit from the web. Dropping it also leaves a single left edge for the eye
    /// to follow, which the badge-name-date arrangement never had — three objects, three
    /// alignments, in the least stable shape there is.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.today)
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            // The mark stands in for the K — the mark itself, bays and all, not a simplified
            // cut of it, and in the brand tint rather than the ink of the word: it is the
            // logo, so it keeps the logo's colour. The bays stay knocked through, which on
            // this screen is the same thing as filling them with the background.
            //
            // Sized to Montserrat's cap height (about 0.7 em) and sat on the baseline, so the
            // three letters share one line.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CageMark.Filled(height: 24)
                    .foregroundStyle(.tint)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text("eo").font(.wordmark(size: 34))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keo")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { capacity }
        .padding(.top, 4)
    }

    /// Ce qu'il reste sur le NAS, en anneau, à hauteur du mot.
    ///
    /// Remonté du bloc « Bibliothèque », où il était la dernière chose de la page : c'est un
    /// état permanent et pas une destination, et un état se lit d'un coup d'oeil en arrivant.
    /// Un anneau plutôt qu'une barre parce qu'il occupe la hauteur d'un logotype au lieu de la
    /// largeur de l'écran, et parce qu'une barre horizontale à côté d'un mot se lirait comme
    /// un chargement en cours.
    @ViewBuilder
    private var capacity: some View {
        if let disk, disk.total > 0 {
            let used = Double(disk.total - disk.free) / Double(disk.total)
            // L'anneau a cote du texte et non au-dessus : trois lignes empilees sous un
            // anneau auraient fait un en-tete plus haut que le logotype, et c'est le mot qui
            // doit mener la page.
            HStack(spacing: 8) {
                Gauge(value: used) {
                    EmptyView()
                } currentValueLabel: {
                    Text(used.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.weight(.semibold))
                        .fontDesign(.rounded)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.62)
                .frame(width: 44, height: 44)
                .tint(nearlyFull ? Theme.warning : Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text((disk.total - disk.free).formatted(.byteCount(style: .file))
                       + " sur " + disk.total.formatted(.byteCount(style: .file)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(weightLabel + " lus")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            // La couleur seule ne dit rien ici : l'etiquette porte la phrase entiere, et le
            // chiffre sous l'anneau porte ce qui compte vraiment — ce qu'il reste.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stockage")
            .accessibilityValue(
                (disk.total - disk.free).formatted(.byteCount(style: .file)) + " utilisés sur "
                + disk.total.formatted(.byteCount(style: .file)) + ", dont "
                + weightLabel + " lus par Keo"
                + (nearlyFull ? ". Le disque est presque plein." : ""))
        }
    }

    /// Which of a year's photos to show on the `rotation`-th turn.
    ///
    /// A year with three photos and a rotation of seven shows its second — the wrap is what
    /// makes a short year keep cycling rather than stick on its last picture.
    static func cover(of items: [Item], at rotation: Int) -> Item? {
        guard !items.isEmpty else { return nil }
        return items[rotation % items.count]
    }

    private func openShownYear() {
        guard let shown else { return }
        destination = .results(title: "Ce jour-là en \(shown.year)", items: shown.items)
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
                                if let cover = Self.cover(of: group.items, at: rotation) {
                                    // The card is 4:3; a square thumbnail left bars down
                                    // both sides of every memory.
                                    Thumb(item: cover, client: client, selected: nil,
                                          lookahead: [], aspect: 4 / 3)
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
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            ForEach(memoriesByYear.indices, id: \.self) { index in
                                Circle()
                                    .fill(.white.opacity(index == memoryPage ? 0.95 : 0.4))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        // Inside the same capsule as the dots, not beside it: it is the same
                        // piece of information — which year, and how long it stays.
                        if !reduceMotion {
                            // Twelve frames a second is plenty for a bar sixty points wide,
                            // and it keeps a permanent timeline on the home screen cheap.
                            TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
                                let width = Self.dotsWidth(memoriesByYear.count)
                                Capsule()
                                    .fill(.white.opacity(0.25))
                                    // Exactly as wide as the row of dots. A capsule given
                                    // only a height takes every point it is offered, and
                                    // dragged the whole badge across the card.
                                    .frame(width: width, height: 2)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.white.opacity(0.9))
                                            .frame(width: width * Self.turnFraction(
                                                since: turnStarted, now: context.date))
                                    }
                                    .clipShape(Capsule())
                            }
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
            .onTapGesture { openShownYear() }
            // Un `onTapGesture` n'est pas un bouton : VoiceOver annonçait une image et
            // n'offrait aucune action, alors que « Derniers éléments » juste en dessous sont
            // de vrais boutons. Les rangées de photos voisines se comportent déjà ainsi.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(shown.map { "Ce jour-là en \($0.year)" } ?? "Ce jour-là")
            .accessibilityAction { openShownYear() }
            // Restarted by its own id on every change, so a manual swipe gets the full dwell
            // instead of being cut short by a timer that had kept running underneath.
            .task(id: memoryPage) {
                let years = memoriesByYear.count
                guard years > 1, !reduceMotion else { return }
                turnStarted = Date()
                try? await Task.sleep(for: .seconds(Self.turnEvery))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    rotation += 1
                    memoryPage = (memoryPage + 1) % years
                }
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
                                           covers: pinCovers[folder.path] ?? [],
                                           client: client, width: 150)
                            }
                            .buttonStyle(.plain)
                            // Pinning happens in Parcourir by long press; unpinning had no
                            // gesture at all from the shelf the pins actually live on.
                            .contextMenu {
                                // Sans rôle destructif : désépingler s'annule en secouant,
                                // et le même geste dans Parcourir n'en porte pas. Deux rouges
                                // différents pour le même verbe, c'était l'écran qui décidait
                                // de la gravité au lieu de l'action.
                                Button("Désépingler", systemImage: "pin.slash") {
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


    // MARK: Derniers ajouts

    /// Ce que le NAS a reçu depuis la dernière fois, tous genres confondus.
    ///
    /// Une liste et non une bande de vignettes : c'est le seul endroit de l'accueil où un
    /// document peut apparaître, et un document n'a pas d'image à montrer. La ligne mène au
    /// dossier d'accueil du fichier, qui est la question qu'on se pose en voyant arriver
    /// quelque chose — « c'est tombé où ? ».
    @ViewBuilder
    private var arrived: some View {
        if !arrivals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Derniers ajouts").font(.title3.bold())
                VStack(spacing: 0) {
                    ForEach(Array(arrivals.enumerated()), id: \.element.id) { index, item in
                        Button {
                            destination = BrowserSource.parent(of: item)
                        } label: {
                            LibraryRow(icon: Self.glyph(for: item.kind),
                                       title: item.name,
                                       detail: BrowserSource.parent(of: item)?.title)
                        }
                        .buttonStyle(.plain)
                        if index < arrivals.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.panel,
                                                 style: .continuous))
            }
        }
    }

    private static func glyph(for kind: Item.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

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
                           role: .destructive) { signingOut = true }
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
        pinCovers = (try? await IndexStore.shared.covers(for: paths, limit: 3)) ?? [:]
        // Des photos, pas des médias : l'étagère s'appelle « Dernières photos », et une vidéo
        // sous ce titre est un contenu qui ne correspond pas à ce qui l'annonce.
        recent = (try? await IndexStore.shared.recentMedia(under: FreeboxClient.rootPath,
                                                           limit: 12, kinds: [.image])) ?? []
        arrivals = (try? await IndexStore.shared.recentlyAdded(under: FreeboxClient.rootPath,
                                                               limit: 6)) ?? []
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
                    // dark fill. Keo's accent is a pale peach in both appearances, where white
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
