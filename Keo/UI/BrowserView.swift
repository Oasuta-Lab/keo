import SwiftUI

struct BrowserView: View {
    let client: FreeboxClient
    let source: BrowserSource

    /// Convenience: most of the view still thinks in folder paths.
    private var path: String { source.folderPath ?? source.id }
    private var title: String { source.title }

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var downloader: Downloader
    @EnvironmentObject private var sync: CloudSync
    @EnvironmentObject private var undoer: Undoer

    /// Split by kind once, at load. Filtering in computed properties re-scanned the whole
    /// listing on every body evaluation, which is what made large folders stutter.
    @State private var contents = FolderContents.empty
    @State private var error: String?
    @State private var loaded = false
    @State private var viewing: Item?
    @State private var selecting = false
    @State private var selection: Set<Item> = []
    @AppStorage("itemOrder") private var order: ItemOrder = .newest
    /// How finely the grid is cut in time, and how small the cells get.
    @AppStorage("granularity") private var granularity: Granularity = .month

    /// Only built when sorting by date — grouping a name-sorted grid by month would be noise.
    @State private var sections: [MediaSection] = []
    /// Which section is under the top edge. Deliberately a reference the rail reads for
    /// itself rather than `@State` this view reads: a `@State` write re-evaluates this
    /// whole body, and the preference publishes on every scroll frame.
    @State private var cursor = SectionCursor()
    /// Position of each photo in the flat media array, so a cell can find its prefetch
    /// window without rebuilding `Array(enumerated())` per section per frame.
    @State private var mediaIndex: [Item.ID: Int] = [:]
    /// The period to land back on after the grid has been rebuilt under the reader.
    @State private var restore: MediaSection.ID?
    /// Capture dates that arrived while the viewer covered the grid. A re-sort behind the
    /// cover is work for an audience of nobody — and it moved the grid out from under the
    /// reader: dismissing then scrolled to the viewed photo's *new* position, surfacing
    /// among other dates. Held here and folded in once the cover is gone.
    @State private var pendingDates: [Item.ID: Date] = [:]
    @Namespace private var zoom
    /// The cell the viewer flies back to. It follows the paging, so closing on the
    /// twentieth photo returns to *that* cell and not to the one originally tapped.
    @State private var anchor: Item.ID?
    @EnvironmentObject private var indexer: Indexer
    @State private var showingIndexing = false
    @State private var showingInvitation = false
    /// Asked once; afterwards the chip and the menu are enough.
    @AppStorage("explainedIndexing") private var explainedIndexing = false
    /// How many files here still have no date, when it is too many to read on the fly.
    @State private var unindexed = 0
    /// Counted during indexing, so a tile can say what is inside without asking the box.
    @State private var folderStats: [String: FolderStats] = [:]
    /// One photo per subfolder, chosen by the index — no extra listing to find it.
    @State private var folderCovers: [String: Item] = [:]
    /// True while the grid shows what the index remembers rather than a fresh listing.
    @State private var fromCache = false
    /// Saved items whose file the index no longer finds on the NAS.
    @State private var missing: [Item] = []

    @State private var collections: [IndexStore.Collection] = []
    @State private var choosingCollection = false
    /// Paths of folders already pinned, so a tile's menu can say the right thing.
    @State private var pinned: Set<String> = []
    /// Set by « Aller au dossier » — a search result says nothing about where it lives.
    @State private var goingTo: BrowserSource?
    /// Paths carrying a note, so a cell can be marked without one query per cell.
    @State private var noted: Set<String> = []
    /// Marked on the tiles, like the notes. One query each per load, not per cell.
    @State private var favouritePaths: Set<String> = []
    @State private var collectedPaths: Set<String> = []
    @State private var annotating: Item?
    /// True when every selected item is already a favourite — the action then unfavourites.
    @State private var selectionIsFavourite = false

    private var sectioned: Bool { order != .name && !sections.isEmpty }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: granularity.cellWidth), spacing: 2)]
    }
    /// Wider than a photo cell: a folder tile has to carry a readable name.
    private let folderColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    fileprivate static let gridSpace = "keo.grid"

    /// The last header that has already passed the top edge: that is the period on screen.
    fileprivate static func topmost(of tops: [String: CGFloat]) -> String? {
        let passed = tops.filter { $0.value <= 1 }
        if let lowest = passed.max(by: { $0.value < $1.value }) { return lowest.key }
        return tops.min(by: { $0.value < $1.value })?.key
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !contents.folders.isEmpty {
                        LazyVGrid(columns: folderColumns, spacing: 10) {
                            ForEach(contents.folders) { folder in
                                NavigationLink(value: folder) {
                                    FolderTile(folder: folder, stats: folderStats[folder.path],
                                               cover: folderCovers[folder.path], client: client,
                                               noted: noted.contains(folder.path))
                                }
                                .buttonStyle(.plain)
                                .disabled(selecting)
                                .contextMenu {
                                    // Files' vocabulary, not a second "this matters" metaphor
                                    // beside the heart. Pinning and favouriting are different
                                    // verbs and had been wearing the same costume.
                                    Button(pinned.contains(folder.path)
                                           ? "Désépingler" : "Épingler",
                                           systemImage: pinned.contains(folder.path)
                                           ? "pin.slash" : "pin") {
                                        togglePin(folder)
                                    }
                                    noteAction(folder)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                    }

                    if sectioned {
                        ForEach(sections) { section in
                            Section {
                                grid(section.items)
                            } header: {
                                SectionHeader(section: section)
                            }
                            .id(section.id)
                        }
                    } else if !contents.media.isEmpty {
                        grid(contents.media)
                    }

                    ForEach(contents.documents) { document in
                        Button { tap(document) } label: {
                            Row(item: document, icon: "doc.fill",
                                selected: selecting ? selection.contains(document) : nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { itemActions(document) }
                    }
                }
            }
            // A zoom back to a cell that scrolled off screen has nowhere to land, so the
            // grid follows the paging before the transition plays.
            .onChange(of: viewing) { previous, now in
                guard previous != nil, now == nil else { return }
                // `at=absent` here with a grid that still lands on the wrong dates would
                // refute the held-dates theory: it would mean the anchor itself was lost.
                trace("viewer dismissed anchor=\(anchor ?? "nil") "
                    + "at=\(anchor.flatMap { mediaIndex[$0] }.map(String.init) ?? "absent") "
                    + "pending=\(pendingDates.count)")
                guard let anchor else { return }
                trace("dismiss scroll to \(anchor) at=\(mediaIndex[anchor].map(String.init) ?? "absent") "
                    + "n=\(contents.media.count)")
                proxy.scrollTo(anchor, anchor: .center)
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(SectionTopKey.self) { tops in
                cursor.id = Self.topmost(of: tops)
            }
            .onChange(of: restore) { _, target in
                guard let target else { return }
                trace("restore scroll to \(target)")
                // No animation: this is not a journey the reader asked for, it is staying
                // where they were while the ground moved underneath.
                proxy.scrollTo(target, anchor: .top)
                restore = nil
            }
            .overlay(alignment: .trailing) {
                if sectioned, !selecting {
                    TimelineRail(sections: sections, cursor: cursor) { id in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
        }
        // Applied right on the scroll view and deliberately *before* `.fullScreenCover`:
        // this modifier publishes a RefreshAction into the environment of everything it wraps,
        // and a cover attached after it inherits that action — the viewer's pager then starts
        // pulling a refresh spinner when you swipe down to dismiss.
        .refreshable { await load() }
        .safeAreaInset(edge: .top, spacing: 0) { missingBanner }
        .overlay { status }
        .overlay(alignment: .bottom) {
            // Root only, and out of the way whenever an action bar is up.
            if indexer.state.isRunning, !indexer.isStalled,
               let progress = indexer.state.progress {
                IndexingChip(fraction: progress.folderFraction,
                             pending: max(progress.folderTotal - progress.folderDone, 0)) {
                    showingIndexing = true
                }
                .padding(.bottom, 8)
            } else if unindexed > 0, !selecting, !downloader.isRunning {
                UnindexedChip(count: unindexed) { showingIndexing = true }
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle(selecting ? selectionTitle : title)
        // Sibling folders used to disagree about their own title size, so navigating made
        // the grid jump. A NAS folder is a place and keeps a large title — it collapses on
        // scroll anyway; results and local collections are lists and stay inline.
        .navigationBarTitleDisplayMode(selecting || !source.isOnNAS ? .inline : .large)
        .navigationDestination(for: BrowserSource.self) { destination in
            BrowserView(client: client, source: destination)
        }
        .navigationDestination(for: Item.self) { folder in
            BrowserView(client: client, source: .folder(folder))
        }
        .navigationDestination(item: $goingTo) { destination in
            BrowserView(client: client, source: destination)
        }
        .fullScreenCover(item: $viewing) { item in
            ViewerView(client: client,
                       items: contents.media.isEmpty ? [item] : contents.media,
                       companions: contents.companions,
                       start: item, anchor: $anchor)
                .navigationTransition(.zoom(sourceID: anchor ?? item.id, in: zoom))
                // Fires once the dismiss transition has landed: re-sorting mid-flight
                // would move the very cell the photo is flying back to.
                .onDisappear { applyPendingDates() }
        }
        .sheet(item: $downloader.share) { payload in
            ShareSheet(urls: payload.urls)
        }
        .sheet(item: $annotating) { item in
            NoteEditor(item: item) { body in
                if body.isEmpty { noted.remove(item.path) } else { noted.insert(item.path) }
            }
        }
        .sheet(isPresented: $showingIndexing) {
            IndexingView(client: client)
        }
        .sheet(isPresented: $showingInvitation) {
            IndexingInvitation(client: client) {
                indexer.start(client: client)
            }
            .onDisappear { explainedIndexing = true }
        }
        // Dates discovered for this folder, whether by the open-folder scan or the full pass.
        .onChange(of: indexer.resolution) { _, found in
            guard let found, found.folder == path else { return }
            // Held, not applied, while the viewer covers the grid. Applying re-sorted a
            // grid nobody could see, and dismissing then scrolled to the viewed photo's
            // new position — the reader surfaced among other dates, with no way back.
            // The `restore` anchor never covered that path: it fired under the cover,
            // and the dismissal's anchor scroll overrode it.
            pendingDates.merge(found.dates) { _, new in new }
            if viewing == nil {
                applyPendingDates()
            } else {
                trace("dates held folder=\(found.folder) +\(found.dates.count) "
                    + "pending=\(pendingDates.count)")
            }
        }
        .alert("Téléchargement interrompu", isPresented: showingError) {
            Button("OK") { downloader.error = nil }
        } message: {
            Text(downloader.error ?? "")
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                DownloadBar(downloader: downloader)
                if selecting { selectionBar }
            }
        }
        .sensoryFeedback(.selection, trigger: selection.count)
        .task(id: source.id) { await load() }
        .task(id: source.id) { await refreshLibrary() }
        // Favourites and collection members arrived from another device land without a tap
        // here: repaint the local sources on each sync transition.
        .onChange(of: sync.status) {
            guard !source.isOnNAS else { return }
            Task { await loadLocal() }
        }
        .onChange(of: selection) { _, _ in Task { await refreshSelectionState() } }
        // Anything that touched a favourite, a collection, a shortcut or a note — from here,
        // from the viewer on top, or from an undo. The marks on the tiles are read once per
        // load, so without this they keep showing the state from before the tap.
        .onChange(of: undoer.revision) { _, _ in
            Task {
                await refreshLibrary()
                await refreshSelectionState()
                if !source.isOnNAS { await loadLocal() }
            }
        }
        .collectionPicker(choosing: $choosingCollection, collections: collections) { collection in
            addSelection(to: collection)
        } create: { name in
            createCollection(named: name)
        }
        .task {
            // A relaunch after iOS killed the app mid-index still has somewhere to pick up.
            if source.isRoot { indexer.resumeIfInterrupted(client: client) }
        }

        // Reordering is a local question: no reason to ask the box again.
        .onChange(of: order) { _, new in
            trace("contents: reordered order=\(new) n=\(contents.media.count)")
            contents = contents.reordered(by: new)
            rebuildSections()
        }
        .onChange(of: granularity) { _, _ in rebuildSections() }
    }

    private func grid(_ items: [Item]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(items) { item in
                Button { tap(item) } label: {
                    Thumb(item: item, client: client,
                          selected: selecting ? selection.contains(item) : nil,
                          lookahead: lookahead(after: item))
                        .overlay(alignment: .topLeading) {
                            Badges(noted: noted.contains(item.path),
                                   favourite: favouritePaths.contains(item.path),
                                   collected: collectedPaths.contains(item.path),
                                   live: contents.companions[item.id] != nil)
                        }
                }
                .buttonStyle(.plain)
                .id(item.id)
                .matchedTransitionSource(id: item.id, in: zoom)
                .contextMenu { itemActions(item) }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func itemActions(_ item: Item) -> some View {
        noteAction(item)
        locate(item)
    }

    @ViewBuilder
    private func noteAction(_ item: Item) -> some View {
        Button(noted.contains(item.path) ? "Modifier la note" : "Ajouter une note",
               systemImage: noted.contains(item.path) ? "text.quote" : "square.and.pencil") {
            annotating = item
        }
    }

    /// Where an item actually lives. A result, a favourite or a collection member is shown
    /// stripped of its folder, which is exactly the context you want back once you found it.
    /// Pointless inside a real folder: you are already there.
    @ViewBuilder
    private func locate(_ item: Item) -> some View {
        if !source.isOnNAS, let parent = BrowserSource.parent(of: item) {
            Button("Aller dans « \(parent.title) »", systemImage: "folder") {
                goingTo = parent
            }
        }
    }


    private func refreshLibrary() async {
        collections = (try? await IndexStore.shared.collections()) ?? []
        pinned = Set((try? await IndexStore.shared.shortcuts())?.map(\.path) ?? [])
        noted = (try? await IndexStore.shared.notedPaths()) ?? []
        favouritePaths = Set((try? await IndexStore.shared.favourites())?.map(\.path) ?? [])
        collectedPaths = (try? await IndexStore.shared.collectedPaths()) ?? []
    }

    private func togglePin(_ folder: Item) {
        Task {
            let on = !pinned.contains(folder.path)
            try? await IndexStore.shared.setShortcut(folder, on)
            await refreshLibrary()
            undoer.record(on ? "« \(folder.name) » épinglé" : "« \(folder.name) » désépinglé") {
                try? await IndexStore.shared.setShortcut(folder, !on)
            }
        }
    }

    /// The action mirrors the selection: all favourites already, so remove; otherwise add.
    private func toggleFavourite() {
        let items = contents.selectable.filter { selection.contains($0) }
        guard !items.isEmpty else { return }
        let adding = !selectionIsFavourite
        Task {
            try? await IndexStore.shared.setFavourite(items, adding)
            await refreshSelectionState()
            await refreshLibrary()
            if source == .favourites { await loadLocal() }
            undoer.record(Undoer.count(items.count, adding ? "favori ajouté" : "favori retiré",
                                       adding ? "favoris ajoutés" : "favoris retirés")) {
                try? await IndexStore.shared.setFavourite(items, !adding)
            }
        }
    }

    private func refreshSelectionState() async {
        let items = contents.selectable.filter { selection.contains($0) }
        guard !items.isEmpty else {
            selectionIsFavourite = false
            return
        }
        var allStarred = true
        for item in items where allStarred {
            allStarred = (try? await IndexStore.shared.isFavourite(item)) ?? false
        }
        selectionIsFavourite = allStarred
    }

    /// Creates it and files the selection in one go, from wherever the user already was.
    private func createCollection(named name: String) {
        let items = contents.selectable.filter { selection.contains($0) }
        guard !items.isEmpty else { return }
        Task {
            guard let id = try? await IndexStore.shared.createCollection(named: name) else { return }
            try? await IndexStore.shared.setMembership(items, in: id, true)
            await refreshLibrary()
            selecting = false
            selection = []
            undoer.record(Undoer.count(items.count, "élément ajouté", "éléments ajoutés")
                        + " à « \(name) »") {
                try? await IndexStore.shared.setMembership(items, in: id, false)
            }
        }
    }

    private func addSelection(to collection: IndexStore.Collection) {
        let items = contents.selectable.filter { selection.contains($0) }
        guard !items.isEmpty else { return }
        Task {
            try? await IndexStore.shared.setMembership(items, in: collection.id, true)
            await refreshLibrary()
            selecting = false
            selection = []
            undoer.record(Undoer.count(items.count, "élément ajouté", "éléments ajoutés")
                        + " à « \(collection.name) »") {
                try? await IndexStore.shared.setMembership(items, in: collection.id, false)
            }
        }
    }

    /// Never purged behind the user's back: a file that is gone is worth saying out loud, and
    /// removing it stays a deliberate tap.
    @ViewBuilder
    private var missingBanner: some View {
        if !missing.isEmpty, !source.isOnNAS {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(missing.count == 1
                         ? "1 élément introuvable sur le NAS"
                         : "\(missing.count) éléments introuvables sur le NAS")
                        .font(.footnote.weight(.medium))
                    Text("Supprimés, ou sur un dossier pas encore indexé")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retirer") { dropMissing() }
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func dropMissing() {
        let doomed = missing
        Task {
            switch source {
            case .favourites:
                try? await IndexStore.shared.setFavourite(doomed, false)
            case .collection(let id, _):
                try? await IndexStore.shared.setMembership(doomed, in: id, false)
            case .folder, .results:
                break
            }
            missing = []
            await loadLocal()
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var status: some View {
        if !loaded {
            ProgressView()
        } else if let error {
            ContentUnavailableView("Connexion impossible", systemImage: "externaldrive.badge.xmark",
                                   description: Text("La Freebox ne répond pas. Ce que Keo a "
                                                   + "déjà lu reste consultable — ce dossier-ci "
                                                   + "n'a simplement jamais été vu.\n\n" + error))
        } else if contents.isEmpty {
            if source == .favourites, sync.status == .recovering {
                // Empty because nothing has arrived yet, not because there is nothing.
                SyncRecoveryView()
            } else {
                // Vocabulary follows the place, not the storage underneath. The most personal
                // tab in the app used to greet an empty library with "Dossier vide" and a
                // folder icon — filesystem words for something that is not a folder.
                switch source {
                case .favourites:
                    ContentUnavailableView {
                        Label("Aucun favori pour l'instant", systemImage: "heart")
                    } description: {
                        Text("Un cœur en plein écran, et la photo t'attendra ici.")
                    }
                case .collection:
                    ContentUnavailableView {
                        Label("Rien ici pour l'instant", systemImage: "square.stack")
                    } description: {
                        Text("Ajoute des photos depuis la grille ou le plein écran : "
                           + "sélection, puis Collection.")
                    }
                case .results:
                    ContentUnavailableView("Rien trouvé", systemImage: "magnifyingglass")
                case .folder:
                    ContentUnavailableView("Ce dossier est vide", systemImage: "folder")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !selecting, contents.selectableCount > 0 {
                Button("Sélectionner", systemImage: "checkmark.circle") { selecting = true }
                    .labelStyle(.iconOnly)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button("OK") {
                    selecting = false
                    selection = []
                }
            } else if contents.selectableCount > 0 {
                // Nothing but what belongs to the grid in front of you. Indexing, statistics
                // and signing out used to live here, in the sort menu of every folder — the
                // machinery on every screen is what makes an app feel like an admin console.
                // They have a room of their own now.
                Menu {
                    Picker("Trier", selection: $order) {
                        ForEach(ItemOrder.allCases, id: \.self) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }

                    if order != .name {
                        Picker("Regrouper", selection: $granularity) {
                            ForEach(Granularity.allCases, id: \.self) { option in
                                Label(option.label, systemImage: option.systemImage).tag(option)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 18) {
            Button(selection.count == contents.selectableCount ? "Aucun" : "Tout") {
                selection = selection.count == contents.selectableCount
                    ? []
                    : Set(contents.selectable)
            }
            .font(.footnote)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())

            Spacer()

            Button { toggleFavourite() } label: {
                Label("Favori", systemImage: selectionIsFavourite ? "heart.fill" : "heart")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(selection.isEmpty)

            Button { choosingCollection = true } label: {
                Label("Collection", systemImage: "square.stack")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(selection.isEmpty)

            Button { start(.photos) } label: {
                Label("Photos", systemImage: "photo.badge.arrow.down")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(!selectionFitsPhotos || downloader.isRunning)

            Button { start(.share) } label: {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(selection.isEmpty || downloader.isRunning)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20)
        // The buttons now carry the height themselves; the old 12 pt would stack on top of
        // their 44 and make the bar a third taller than it was.
        .padding(.vertical, 2)
        .background(.bar)
    }

    /// The photo library only takes photos and videos — a PDF would fail mid-batch.
    private var selectionFitsPhotos: Bool {
        !selection.isEmpty && selection.allSatisfy(\.isMedia)
    }

    private var selectionTitle: String {
        selection.isEmpty
            ? "Sélectionner"
            : "\(selection.count) sélectionné\(selection.count > 1 ? "s" : "")"
    }

    private var showingError: Binding<Bool> {
        Binding(get: { downloader.error != nil }, set: { if !$0 { downloader.error = nil } })
    }

    /// The window a cell warms up when it appears — roughly two screens ahead.
    private func lookahead(after item: Item) -> ArraySlice<Item> {
        guard let index = mediaIndex[item.id] else { return [] }
        let start = index + 1
        guard start < contents.media.count else { return [] }
        return contents.media[start..<min(start + 24, contents.media.count)]
    }

    // MARK: Actions

    private func tap(_ item: Item) {
        if selecting {
            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        } else {
            anchor = item.id
            viewing = item
        }
    }

    private func start(_ destination: Downloader.Destination) {
        let ordered = contents.selectable.filter { selection.contains($0) }
        downloader.save(ordered, from: client, to: destination)
        selecting = false
        selection = []
    }

    /// Known dates are folded in before the first paint; whatever is left is handed to the
    /// indexer, which is the only thing that talks to the box about dates.
    private func resolveDates() async {
        do {
            await offerIndexing()
            let folders = contents.folders.map(\.path)
            folderStats = (try? await IndexStore.shared.stats(for: folders)) ?? [:]
            folderCovers = (try? await IndexStore.shared.covers(for: folders)) ?? [:]

            let known = try await IndexStore.shared.known(contents.media, in: path)
            if !known.isEmpty {
                trace("contents: known dates n=\(known.count)")
                contents = contents.applying(known, order: order)
                rebuildSections()
            }

            let pending = try await IndexStore.shared.unread(contents.media, in: path)
            guard order != .name, !pending.isEmpty else {
                unindexed = 0
                return
            }

            // Beyond this, reading on open grinds every time you walk in. Those belong to the
            // deliberate pass from the indexing screen.
            if pending.count > Self.automaticLimit {
                unindexed = pending.count
            } else {
                unindexed = 0
                indexer.prioritise(folder: path, items: pending, client: client)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let automaticLimit = 2_000

    /// Nothing indexed yet: say why it matters before the user concludes the app is broken.
    private func offerIndexing() async {
        guard source.isRoot, !explainedIndexing, !indexer.state.isRunning,
              let empty = try? await IndexStore.shared.fileCount(), empty == 0 else { return }
        showingInvitation = true
    }

    private func loadLocal() async {
        do {
            let saved: [Item]
            switch source {
            case .favourites: saved = try await IndexStore.shared.favourites()
            case .collection(let id, _): saved = try await IndexStore.shared.items(in: id)
            case .folder: saved = []
            // Straight out of the index a moment ago: re-resolving would be pure waste.
            case .results(_, let items):
                trace("contents: results n=\(items.count)")
            contents = FolderContents(items, order: order)
                rebuildSections()
                error = nil
                loaded = true
                return
            }
            // A moved file is quietly repathed; only a genuinely absent one is set aside.
            let resolved = try await IndexStore.shared.resolve(saved)
            missing = resolved.missing
            trace("contents: local n=\(resolved.present.count)")
            contents = FolderContents(resolved.present, order: order)
            rebuildSections()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Folds held capture dates into the grid. Applying them *re-sorts* it: a photo that
    /// just learned it was taken in 2019 leaves the top and lands in the middle of the
    /// list. The sort still happens — a half-sorted timeline would be worse — but the
    /// scroll lands back on the period being read, when that period still exists.
    private func applyPendingDates() {
        guard !pendingDates.isEmpty else { return }
        let looking = cursor.id
        contents = contents.applying(pendingDates, order: order)
        pendingDates = [:]
        rebuildSections()
        unindexed = 0
        let kept = sectioned && looking.map { id in
            sections.contains { $0.id == id }
        } == true
        if kept { restore = looking }
        trace("dates applied sections=\(sections.count) "
            + "looking=\(looking ?? "nil") kept=\(kept)")
    }

    private func rebuildSections() {
        let looking = cursor.id
        sections = order == .name
            ? []
            : MediaGrouping.sections(from: contents.media, granularity: granularity)
        // Keep the period the reader was on if it still exists. Resetting to the first
        // section threw the rail's highlight back to the top every time a batch of dates
        // landed — which, during an indexing pass, is every few seconds.
        cursor.id = sections.contains { $0.id == looking } ? looking : sections.first?.id
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: nothing guarantees distinct
        // paths in a hand-assembled list, and a duplicate must not kill the grid over a
        // prefetch hint.
        mediaIndex = Dictionary(contents.media.enumerated().map { ($0.element.id, $0.offset) },
                                uniquingKeysWith: { first, _ in first })
    }

    private func load() async {
        // `covered=true` here would name a rival mechanism: the listing reloading — and
        // re-sorting — behind the viewer, with no resolution involved at all.
        trace("load folder=\(path) covered=\(viewing != nil) loaded=\(loaded)")
        // Local collections come straight from the index; there is nothing to ask the box.
        guard source.isOnNAS else {
            await loadLocal()
            return
        }

        // Paint what the last pass saw, straight away: the box needs seconds on a folder of
        // 14 600 files, the index answers in milliseconds.
        if contents.isEmpty, let remembered = try? await IndexStore.shared.listing(path),
           !remembered.isEmpty {
            trace("contents: cache n=\(remembered.count)")
            contents = FolderContents(remembered, order: order)
            rebuildSections()
            fromCache = true
            loaded = true
        }

        let painted = fromCache
        do {
            // The first page paints in about 200 ms; showing it would shrink a grid already
            // filled from the index, so it is only worth it when there was nothing to show.
            let live = try await client.list(path, order: order) { firstPage in
                Task { @MainActor in
                    guard !painted, contents.isEmpty else { return }
                    contents = firstPage
                    rebuildSections()
                    loaded = true
                }
            }
            trace("contents: live n=\(live.media.count) was=\(contents.media.count)")
            contents = live
            fromCache = false
            rebuildSections()
            error = nil
            await resolveDates()
        } catch {
            // What the index remembers beats an error page; keep showing it.
            if !painted { self.error = error.localizedDescription }
        }
        loaded = true
    }
}

// MARK: - Sections

private struct SectionHeader: View {
    let section: MediaSection

    var body: some View {
        // Count sits next to the title, not on the trailing edge: that side belongs to the
        // timeline rail's year labels, and the two were drawing on top of each other.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.headline)
            Text("\(section.items.count)")
                .font(.caption)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SectionTopKey.self,
                    value: [section.id: geometry.frame(in: .named(BrowserView.gridSpace)).minY]
                )
            }
        )
    }
}

/// Where each rendered header sits, so the rail can highlight the period on screen.
private struct SectionTopKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Cells

/// Shared with the home screen, which shows the same cells in its memory card, its pinned
/// shelf and its recent strip — and benefits from the same prefetch and cache.
struct Thumb: View {
    let item: Item
    let client: FreeboxClient
    /// nil when not selecting.
    let selected: Bool?
    let lookahead: ArraySlice<Item>

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white,
                                         selected ? AnyShapeStyle(.tint)
                                                  : AnyShapeStyle(.black.opacity(0.3)))
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if selected == true { Color.black.opacity(0.25) }
            }
            .accessibilityLabel(item.name)
            .accessibilityValue(selected.map { $0 ? "Sélectionné" : "Non sélectionné" } ?? "")
            .accessibilityAddTraits(.isImage)
            .task(id: item.path) {
                // Warm what is coming before awaiting our own, so the queue fills in scroll order.
                await ThumbnailPipeline.shared.prefetch(Array(lookahead), client: client)
                let loaded = await ThumbnailPipeline.shared.thumbnail(for: item, client: client)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }
    }
}

private struct FolderTile: View {
    let folder: Item
    /// Absent until the folder has been indexed; the tile simply says less.
    let stats: FolderStats?
    /// A photo from inside, picked by the index. Absent until a pass has seen one.
    let cover: Item?
    let client: FreeboxClient
    let noted: Bool

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.tint.opacity(0.16))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.tint)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Badges(noted: noted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let count = stats?.mediaCount ?? folder.childCount, count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.weight(.medium))
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .task(id: cover?.path) {
                guard let cover else { return }
                // Default size on purpose: the cover then shares its cache entry with the grid
                // cell of the folder being opened, instead of fetching the same photo twice.
                let loaded = await ThumbnailPipeline.shared.thumbnail(for: cover, client: client)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }

            Text(folder.name)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.horizontal, 2)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
    }

    /// "8,2 Go · 2019 – 2024", trimmed to whatever is actually known.
    private var detail: String? {
        guard let stats else { return nil }
        let parts = [
            stats.bytes.map { Int64($0).formatted(.byteCount(style: .file)) },
            stats.span,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct Row: View {
    let item: Item
    let icon: String
    let selected: Bool?

    var body: some View {
        HStack(spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                if !item.isDirectory {
                    Text(item.size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
