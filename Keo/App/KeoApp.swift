import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()
    // The shared instance, so a background task handler and the UI drive the same walk.
    @StateObject private var indexer = Indexer.shared
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
            // Une demande en attente, toujours : `submit` remplace celle de même identifiant,
            // donc relancer l'app n'en empile pas deux. C'est ce qui permet à Keo d'apprendre
            // qu'un fichier est arrivé sans qu'on ait eu à y penser.
            .task { PeriodicDiscovery.schedule() }
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
    /// A sheet rather than a push: the statistics are the same screen whichever tab is open,
    /// and pushing them would bury them under whatever stack happened to be in front.
    @State private var showingStats = false

    var body: some View {
        TabView(selection: selection) {
            Tab(value: Place.home) {
                NavigationStack(path: $homePath) {
                    HomeView(client: client, boxName: boxName)
                }
                .environment(\.stackPath, $homePath)
            } label: {
                // The mark replaces the house, in a cut drawn for this size — see
                // `glyph_svg` in Design/icon/build.py.
                //
                // Labels are hidden by the owner's choice: the app has five destinations
                // and one user who knows them. `Label` keeps the title regardless, so
                // VoiceOver still announces « Accueil » — hiding text from sight must
                // never hide it from assistive technology.
                Label("Accueil", image: "MarkGlyph").labelStyle(.iconOnly)
            }

            Tab(value: Place.browse) {
                NavigationStack(path: $browsePath) {
                    BrowserView(client: client,
                                source: .folder(path: FreeboxClient.rootPath, title: boxName),
                                boxName: boxName, root: true)
                }
                .environment(\.stackPath, $browsePath)
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Parcourir", systemImage: "folder")
                    .environment(\.symbolVariants, .none)
                    .labelStyle(.iconOnly)
            }

            Tab(value: Place.favourites) {
                NavigationStack(path: $favouritesPath) {
                    BrowserView(client: client, source: .favourites, root: true)
                }
                .environment(\.stackPath, $favouritesPath)
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Favoris", systemImage: "heart")
                    .environment(\.symbolVariants, .none)
                    .labelStyle(.iconOnly)
            }

            Tab(value: Place.collections) {
                NavigationStack(path: $collectionsPath) {
                    CollectionsView(client: client)
                }
                .environment(\.stackPath, $collectionsPath)
            } label: {
                // A tab bar fills its symbols by default; outline reads lighter.
                Label("Collections", systemImage: "square.stack")
                    .environment(\.symbolVariants, .none)
                    .labelStyle(.iconOnly)
            }

            Tab(value: Place.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(client: client, seed: $searchSeed)
                }
                .environment(\.stackPath, $searchPath)
            } label: {
                // Measured on an iPhone running iOS 27: the search role does NOT get a
                // control of its own here — leaving it the default label only brought its
                // title back inside the same pill. So it is spelled out like the others,
                // which at least lets it be icon-only. The title still reaches VoiceOver.
                Label("Recherche", systemImage: "magnifyingglass").labelStyle(.iconOnly)
            }
        }
        .modifier(ModernTabBar())
        .overlay(alignment: .bottom) {
            UndoBanner().padding(.bottom, 8)
        }
        .sheet(isPresented: $showingStats) { StatsView(client: client) }
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
        case .statistics:
            showingStats = true
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
/// The two things the tab bar asks for on iOS 26 and later.
///
/// `tabViewSearchActivation(.searchTabSelection)` is what sets the search tab apart from the
/// others, in a control of its own at the trailing edge — the way Photos does it. It reads
/// like an unrelated setting, and the reason is buried in UIKit: on iOS 27 the detached
/// treatment is given to the *prominent* tab, and `UITabBarController.prominentTabIdentifier`
/// says a search tab only earns it by default when it activates search automatically. On
/// iOS 26 `role: .search` was detached unconditionally; recompiling against the iOS 27 SDK
/// is what put it back in the pill. This is the SwiftUI spelling of that opt-in.
///
/// The bargain that comes with it: the search tab now raises its field the moment it is
/// touched, and cancelling returns to the tab you came from. That is the system behaviour,
/// not an accident.
private struct ModernTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}
