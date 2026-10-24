import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()
    @StateObject private var indexer = Indexer()

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
            .preferredColorScheme(.dark)
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

    enum Tab: Hashable { case browse, favourites, collections }

    @State private var tab: Tab = .browse
    @State private var browsePath = NavigationPath()
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
