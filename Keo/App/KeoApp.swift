import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()
    @StateObject private var indexer = Indexer()
    @StateObject private var sync = CloudSync()

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    Shelf(client: client, boxName: store.boxName)
                } else {
                    ConnectView()
                }
            }
            .environmentObject(store)
            .environmentObject(downloader)
            .environmentObject(indexer)
            .environmentObject(sync)
            .preferredColorScheme(.dark)
            // Independent of the Freebox pairing: favourites can come back from iCloud
            // before the box has ever answered.
            .task { await sync.start() }
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

    enum Place: Hashable { case browse, shortcuts, favourites, collections, search }

    @State private var place: Place = .browse
    @State private var browsePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var shortcutsPath = NavigationPath()
    @State private var favouritesPath = NavigationPath()
    @State private var collectionsPath = NavigationPath()

    var body: some View {
        TabView(selection: selection) {
            Tab(value: Place.browse) {
                NavigationStack(path: $browsePath) {
                    BrowserView(client: client,
                                source: .folder(path: FreeboxClient.rootPath, title: boxName))
                }
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Parcourir", systemImage: "folder").environment(\.symbolVariants, .none)
            }

            Tab(value: Place.shortcuts) {
                NavigationStack(path: $shortcutsPath) {
                    ShortcutsView(client: client)
                }
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Raccourcis", systemImage: "star").environment(\.symbolVariants, .none)
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
                    SearchView(client: client)
                }
            }
        }
        .modifier(MinimisingTabBar())
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
        case .browse: browsePath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .shortcuts: shortcutsPath = NavigationPath()
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
