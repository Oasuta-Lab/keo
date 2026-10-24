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

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(contents.folders) { folder in
                    NavigationLink(value: folder) {
                        Row(item: folder, icon: "folder.fill", selected: nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(selecting)
                }

                if !contents.media.isEmpty {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(contents.media.enumerated()), id: \.element) { index, item in
                            Button { tap(item) } label: {
                                Thumb(item: item, client: client,
                                      selected: selecting ? selection.contains(item) : nil,
                                      lookahead: lookahead(after: index))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
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
        .overlay { status }
        .overlay(alignment: .bottom) {
            // Root only, and out of the way whenever an action bar is up.
            if path == FreeboxClient.rootPath, !selecting, !downloader.isRunning {
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
        .refreshable { await load() }
        // Reordering is a local question: no reason to ask the box again.
        .onChange(of: order) { _, new in contents = contents.reordered(by: new) }
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
                    if path == FreeboxClient.rootPath {
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

    private func load() async {
        do {
            contents = try await client.list(path, order: order)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
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
