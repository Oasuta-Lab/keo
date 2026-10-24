import SwiftUI

struct BrowserView: View {
    let client: FreeboxClient
    let path: String
    let title: String

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var downloader: Downloader

    /// Split by kind once, at load. Filtering in computed properties re-scanned the whole
    /// listing on every body evaluation, which is what made large folders stutter.
    @State private var contents = FolderContents.empty
    @State private var error: String?
    @State private var loaded = false
    @State private var viewing: Item?
    @State private var selecting = false
    @State private var selection: Set<Item> = []
    @AppStorage("itemOrder") private var order: ItemOrder = .newest

    /// Only built when sorting by date — grouping a name-sorted grid by month would be noise.
    @State private var sections: [MediaSection] = []
    @State private var activeSection: MediaSection.ID?
    @EnvironmentObject private var indexer: Indexer
    @State private var showingIndexing = false
    /// How many files here still have no date, when it is too many to read on the fly.
    @State private var unindexed = 0
    /// Counted during indexing, so a tile can say what is inside without asking the box.
    @State private var folderStats: [String: FolderStats] = [:]

    private var sectioned: Bool { order != .name && !sections.isEmpty }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]
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
                                    FolderTile(folder: folder, stats: folderStats[folder.path])
                                }
                                .buttonStyle(.plain)
                                .disabled(selecting)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                    }

                    if sectioned {
                        ForEach(sections) { section in
                            Section {
                                grid(section.items, from: section.startIndex)
                            } header: {
                                SectionHeader(section: section)
                            }
                            .id(section.id)
                        }
                    } else if !contents.media.isEmpty {
                        grid(contents.media, from: 0)
                    }

                    ForEach(contents.documents) { document in
                        Button { tap(document) } label: {
                            Row(item: document, icon: "doc.fill",
                                selected: selecting ? selection.contains(document) : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(SectionTopKey.self) { tops in
                activeSection = Self.topmost(of: tops)
            }
            .overlay(alignment: .trailing) {
                if sectioned, !selecting {
                    TimelineRail(sections: sections, activeID: activeSection) { id in
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
        .overlay { status }
        .overlay(alignment: .bottom) {
            // Root only, and out of the way whenever an action bar is up.
            if indexer.state.isRunning, let progress = indexer.state.progress {
                IndexingChip(fraction: progress.folderFraction,
                             pending: max(progress.folderTotal - progress.folderDone, 0)) {
                    showingIndexing = true
                }
                .padding(.bottom, 8)
            } else if unindexed > 0, !selecting, !downloader.isRunning {
                UnindexedChip(count: unindexed) { showingIndexing = true }
                    .padding(.bottom, 8)
            } else if path == FreeboxClient.rootPath, !selecting, !downloader.isRunning {
                BuildStampLabel().padding(.bottom, 8)
            }
        }
        .navigationTitle(selecting ? selectionTitle : title)
        .navigationBarTitleDisplayMode(selecting || contents.folders.isEmpty ? .inline : .large)
        .navigationDestination(for: Item.self) { folder in
            BrowserView(client: client, path: folder.path, title: folder.name)
        }
        .fullScreenCover(item: $viewing) { item in
            ViewerView(client: client,
                       items: contents.media.isEmpty ? [item] : contents.media,
                       start: item)
        }
        .sheet(item: $downloader.share) { payload in
            ShareSheet(urls: payload.urls)
        }
        .sheet(isPresented: $showingIndexing) {
            IndexingView(client: client)
        }
        // Dates discovered for this folder, whether by the open-folder scan or the full pass.
        .onChange(of: indexer.resolution) { _, found in
            guard let found, found.folder == path else { return }
            contents = contents.applying(found.dates, order: order)
            rebuildSections()
            unindexed = 0
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
        .task(id: path) { await load() }

        // Reordering is a local question: no reason to ask the box again.
        .onChange(of: order) { _, new in
            contents = contents.reordered(by: new)
            rebuildSections()
        }
    }

    /// `offset` is the position of the first item inside the flat media array, so each cell
    /// can still work out its prefetch window.
    private func grid(_ items: [Item], from offset: Int) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button { tap(item) } label: {
                    Thumb(item: item, client: client,
                          selected: selecting ? selection.contains(item) : nil,
                          lookahead: lookahead(after: offset + index))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Pieces

    @ViewBuilder
    private var status: some View {
        if !loaded {
            ProgressView()
        } else if let error {
            ContentUnavailableView("Connexion impossible", systemImage: "externaldrive.badge.xmark",
                                   description: Text(error))
        } else if contents.isEmpty {
            ContentUnavailableView("Dossier vide", systemImage: "folder")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button("OK") {
                    selecting = false
                    selection = []
                }
            } else {
                Menu {
                    if contents.selectableCount > 0 {
                        Button("Sélectionner", systemImage: "checkmark.circle") { selecting = true }

                        Picker("Trier", selection: $order) {
                            ForEach(ItemOrder.allCases, id: \.self) { option in
                                Label(option.label, systemImage: option.systemImage).tag(option)
                            }
                        }
                    }
                    Divider()
                    Button("Indexation des dates…", systemImage: "calendar.badge.clock") {
                        showingIndexing = true
                    }

                    if path == FreeboxClient.rootPath {
                        Divider()
                        Button("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive) { store.signOut() }
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

            Spacer()

            Button { start(.photos) } label: {
                Label("Photos", systemImage: "photo.badge.arrow.down")
            }
            .disabled(!selectionFitsPhotos || downloader.isRunning)

            Button { start(.share) } label: {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty || downloader.isRunning)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
    private func lookahead(after index: Int) -> ArraySlice<Item> {
        let start = index + 1
        guard start < contents.media.count else { return [] }
        return contents.media[start..<min(start + 24, contents.media.count)]
    }

    // MARK: Actions

    private func tap(_ item: Item) {
        if selecting {
            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        } else {
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
            folderStats = (try? await IndexStore.shared.stats(
                for: contents.folders.map(\.path)
            )) ?? [:]

            let known = try await IndexStore.shared.known(contents.media, in: path)
            if !known.isEmpty {
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

    private func rebuildSections() {
        sections = order == .name ? [] : MediaGrouping.sections(from: contents.media)
        activeSection = sections.first?.id
    }

    private func load() async {
        do {
            // The first page paints in about 200 ms; the rest lands a couple of seconds later.
            contents = try await client.list(path, order: order) { firstPage in
                Task { @MainActor in
                    guard contents.isEmpty else { return }
                    contents = firstPage
                    rebuildSections()
                    loaded = true
                }
            }
            rebuildSections()
            error = nil
            await resolveDates()
        } catch {
            self.error = error.localizedDescription
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
                .font(.caption.monospacedDigit())
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

private struct Thumb: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.tint.opacity(0.16))
                    .aspectRatio(4 / 3, contentMode: .fit)

                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let count = stats?.mediaCount ?? folder.childCount, count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
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
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
