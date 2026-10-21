import SwiftUI

struct BrowserView: View {
    let client: DAVClient
    let url: URL
    let title: String

    @EnvironmentObject private var store: Store
    @State private var items: [DAVItem] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var viewing: DAVItem?

    private var folders: [DAVItem] { items.filter { $0.kind == .folder } }
    private var media: [DAVItem] { items.filter { $0.kind == .image || $0.kind == .video } }
    private var documents: [DAVItem] { items.filter { $0.kind == .other } }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(folders) { folder in
                    NavigationLink(value: folder) {
                        Row(item: folder, icon: "folder.fill")
                    }
                    .buttonStyle(.plain)
                }

                if !media.isEmpty {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(media) { item in
                            Button { viewing = item } label: { Thumb(item: item, client: client) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                ForEach(documents) { document in
                    Button { viewing = document } label: {
                        Row(item: document, icon: "doc.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Connexion impossible", systemImage: "externaldrive.badge.xmark",
                                       description: Text(error))
            } else if items.isEmpty {
                ContentUnavailableView("Dossier vide", systemImage: "folder")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(folders.isEmpty ? .inline : .large)
        .navigationDestination(for: DAVItem.self) { folder in
            BrowserView(client: client, url: folder.url, title: folder.name)
        }
        .fullScreenCover(item: $viewing) { item in
            ViewerView(client: client, items: media.isEmpty ? [item] : media, start: item)
        }
        .toolbar {
            if url == client.root {
                Button("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right") {
                    store.signOut()
                }
            }
        }
        .task(id: url) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = try await client.list(url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

// MARK: - Cells

private struct Thumb: View {
    let item: DAVItem
    let client: DAVClient

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
            .task(id: item.url) {
                let loaded = await ThumbCache.shared.thumbnail(for: item, client: client)
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }
    }
}

private struct Row: View {
    let item: DAVItem
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
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
