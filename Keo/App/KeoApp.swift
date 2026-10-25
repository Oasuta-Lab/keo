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

/// The three top-level places, as a tab bar.
///
/// A side drawer would have been the obvious shape for this, and it is exactly what Apple's
/// guidelines rule out: navigation hidden behind an icon is navigation nobody finds. Tabs are
/// what Photos itself uses for the same split.
private struct Shelf: View {
    let client: FreeboxClient
    let boxName: String

    enum Tab: Hashable { case browse, shortcuts, favourites, collections }

    @EnvironmentObject private var indexer: Indexer
    @State private var tab: Tab = .browse
    @State private var browsePath = NavigationPath()
    @State private var shortcutsPath = NavigationPath()
    @State private var favouritesPath = NavigationPath()
    @State private var collectionsPath = NavigationPath()

    var body: some View {
        TabView(selection: selection) {
            NavigationStack(path: $browsePath) {
                BrowserView(client: client,
                            source: .folder(path: FreeboxClient.rootPath, title: boxName))
            }
            .tabItem { Label("Parcourir", systemImage: "folder") }
            .tag(Tab.browse)

            NavigationStack(path: $shortcutsPath) {
                ShortcutsView(client: client)
            }
            .tabItem { Label("Raccourcis", systemImage: "star") }
            .tag(Tab.shortcuts)

            NavigationStack(path: $favouritesPath) {
                BrowserView(client: client, source: .favourites)
            }
            .tabItem { Label("Favoris", systemImage: "heart") }
            .tag(Tab.favourites)

            NavigationStack(path: $collectionsPath) {
                CollectionsView(client: client)
            }
            .tabItem { Label("Collections", systemImage: "square.stack") }
            .tag(Tab.collections)
        }
        .modifier(MinimisingTabBar())
        // The widget has no client of its own, so its photos can only be made here, while
        // the box is reachable and someone is looking at the app anyway.
        .task(priority: .utility) {
            await WidgetRenderer.refresh(client: client, indexing: indexer.state.isRunning)
        }
    }

    /// Tapping the tab you are already on returns to its root — the behaviour every iOS app
    /// has, and the quickest way back to the top of the NAS.
    private var selection: Binding<Tab> {
        Binding(get: { tab }, set: { chosen in
            if chosen == tab { popToRoot(chosen) }
            tab = chosen
        })
    }

    private func popToRoot(_ tab: Tab) {
        switch tab {
        case .browse: browsePath = NavigationPath()
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
