import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()
    @StateObject private var indexer = Indexer()
    @StateObject private var sync = CloudSync()
    @StateObject private var undoer = Undoer()
    /// Held here rather than in `Shelf`: a `keo://` URL can land before the box
    /// has answered, and the shelf does not exist yet at that point.
    @State private var link: DeepLink?

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    Shelf(client: client, boxName: store.boxName, link: $link)
                } else {
                    ConnectView()
                }
            }
            .environmentObject(store)
            .environmentObject(downloader)
            .environmentObject(indexer)
            .environmentObject(sync)
            .environmentObject(undoer)
            // Independent of the Freebox pairing: favourites can come back from iCloud
            // before the box has ever answered.
            .task { await sync.start() }
            .onOpenURL { link = DeepLink($0) }
            // Zero-sized, and the only place a shake is heard. It gives up first responder
            // to any text field that wants it, which is right: while typing, a shake belongs
            // to the field's own undo.
            .background(ShakeCatcher { undoer.undo() })
        }
    }
}

/// The top-level places, as a tab bar.
///
/// A side drawer would have been the obvious shape for this, and it is exactly what Apple's
/// guidelines rule out: navigation hidden behind an icon is navigation nobody finds. Tabs are
/// what Photos itself uses for the same split.
///
/// Search carries `TabRole.search`, so iOS places it where it places search everywhere else —
/// apart, at the trailing end — instead of wedging a fifth equal tab into the row.
private struct Shelf: View {
    let client: FreeboxClient
    let boxName: String
    @Binding var link: DeepLink?

    enum Place: Hashable { case home, browse, favourites, collections, search }

    @EnvironmentObject private var indexer: Indexer
    @State private var place: Place = .home
    @State private var browsePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchSeed: SearchQuery?
    @State private var homePath = NavigationPath()
    @State private var favouritesPath = NavigationPath()
    @State private var collectionsPath = NavigationPath()

    var body: some View {
        TabView(selection: selection) {
            Tab(value: Place.home) {
                NavigationStack(path: $homePath) {
                    HomeView(client: client, boxName: boxName)
                }
            } label: {
                Label("Accueil", systemImage: "house").environment(\.symbolVariants, .none)
            }

            Tab(value: Place.browse) {
                NavigationStack(path: $browsePath) {
                    BrowserView(client: client,
                                source: .folder(path: FreeboxClient.rootPath, title: boxName))
                }
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Parcourir", systemImage: "folder").environment(\.symbolVariants, .none)
            }

            Tab(value: Place.favourites) {
                NavigationStack(path: $favouritesPath) {
                    BrowserView(client: client, source: .favourites)
                }
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Favoris", systemImage: "heart").environment(\.symbolVariants, .none)
            }

            Tab(value: Place.collections) {
                NavigationStack(path: $collectionsPath) {
                    CollectionsView(client: client)
                }
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Collections", systemImage: "square.stack").environment(\.symbolVariants, .none)
            }

            Tab(value: Place.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(client: client, seed: $searchSeed)
                }
            }
        }
        .modifier(MinimisingTabBar())
        .overlay(alignment: .bottom) {
            UndoBanner().padding(.bottom, 8)
        }
        .onChange(of: link) { _, now in
            guard let now else { return }
            open(now)
            link = nil
        }
        // The widget has no client of its own, so its photos can only be made here, while
        // the box is reachable and someone is looking at the app anyway.
        .task(priority: .utility) {
            await WidgetRenderer.refresh(client: client, indexing: indexer.state.isRunning)
        }
    }

    /// A tap on a widget. Deliberately resets the stack before pushing: arriving six levels
    /// deep under whatever was open last is not what "open this folder" means.
    private func open(_ link: DeepLink) {
        switch link {
        case .folder(let path):
            place = .browse
            browsePath = NavigationPath()
            guard let title = DeepLink.title(for: path) else { return }
            browsePath.append(BrowserSource.folder(path: path, title: title))
        case .day(let day):
            place = .search
            searchSeed = SearchQuery(period: .between(day, day))
        }
    }

    /// Tapping the tab you are already on returns to its root — the behaviour every iOS app
    /// has, and the quickest way back to the top of the NAS.
    private var selection: Binding<Place> {
        Binding(get: { place }, set: { chosen in
            if chosen == place { popToRoot(chosen) }
            place = chosen
        })
    }

    private func popToRoot(_ place: Place) {
        switch place {
        case .home: homePath = NavigationPath()
        case .browse: browsePath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .favourites: favouritesPath = NavigationPath()
        case .collections: collectionsPath = NavigationPath()
        }
    }
}

/// On iOS 26 the bar shrinks out of the way as you scroll down, so it costs the grid nothing.
private struct MinimisingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
