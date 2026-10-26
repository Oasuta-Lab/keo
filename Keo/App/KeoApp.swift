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
    @Environment(\.scenePhase) private var scenePhase

    init() { PeriodicDiscovery.register() }

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    Shelf(client: client, boxName: store.boxName, link: $link)
                } else {
                    ConnectView()
                }
            }
            // One banner, at the root, for a failure that can surface from anywhere: a
            // grid, the viewer, an indexing walk, a background wake. The views know nothing
            // about it and keep showing the local index.
            //
            // **Before** the `environmentObject`s, and that is not a layout detail: the
            // content of a `safeAreaInset` placed after them is not in the subtree they
            // populate. The banner showed, then `@EnvironmentObject` trapped on the first
            // tap — « Réessayer » closed the app.
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.authorizationLost { AuthorizationBanner() }
            }
            // Floating rather than inset: a walk lasts minutes and crosses every screen,
            // and a strip that pushes the content down three points makes it jump twice per
            // pass. Both sit on top, and displace nothing.
            .overlay(alignment: .top) {
                Group {
                    if let report = indexer.lastSummary {
                        WalkReportCard(summary: report) { indexer.lastSummary = nil }
                    }
                }
                .animation(.snappy, value: indexer.lastSummary)
            }
            .environmentObject(store)
            .environmentObject(downloader)
            .environmentObject(indexer)
            .environmentObject(sync)
            .environmentObject(undoer)
            // The token can arrive through iCloud while the app is in the background, and
            // the keychain sometimes takes minutes. On return, retry silently.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.retryWithFreshToken()
            }
            // Independent of the Freebox pairing: favourites can come back from iCloud
            // before the box has ever answered.
            .task { await sync.start() }
            // One pending request, always: `submit` replaces the one with the same
            // identifier, so relaunching the app never stacks two. This is what lets Keo
            // learn that a file has arrived without anyone having to think about it. The
            // *handler* is registered in `init` — see `PeriodicDiscovery.register`.
            .task { PeriodicDiscovery.schedule() }
            // The last pass's report lives in the index, not in memory: without this, the
            // Indexation screen and the home row start out mute on every launch.
            .task { await indexer.restoreLastPass() }
            .onOpenURL { link = DeepLink($0) }
            // Zero-sized, and the only place a shake is heard. It gives up first responder
            // to any text field that wants it, which is right: while typing, a shake belongs
            // to the field's own undo.
            .background(ShakeCatcher { undoer.undo() })
        }
    }
}


/// Tells the one failure the owner must handle themselves, and what it means.
///
/// It does not cover "the box is out of reach": being away from home is this app's normal
/// state, and everything indexed stays browsable. It only appears on a refusal **named** by
/// the Freebox, one that survived reopening the session and rereading the keychain.
///
/// The first word goes to the most likely explanation, and it is the one that has bitten:
/// another device just paired, the box only recognises one token per application, and the
/// fresh token arrives through iCloud a few minutes later. Pressing ✓ works too, but revokes
/// the other device in turn — better to say so before sending someone to do it.
private struct AuthorizationBanner: View {
    @EnvironmentObject private var store: Store
    @State private var repairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("La Freebox ne reconnaît plus Keo", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.warning)

            Text("Si un autre appareil vient d'être associé, l'autorisation voyage par "
               + "iCloud : attends une minute, ça se remet seul. Sinon, il faut réassocier "
               + "Keo en appuyant sur ✓ sur la face avant de la box.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Réessayer") { Task { await store.retryWithFreshToken() } }
                Button("Réassocier") { repairing = true }
            }
            .font(.footnote.weight(.medium))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: $repairing) { ReassociateSheet() }
    }
}

/// What a finished walk changed, said once and then forgotten.
///
/// It only appears after a **complete** pass. An interrupted pass knows what it saw, not
/// what it missed, and « Rien de neuf » coming from a walk that reached four folders out of
/// eight thousand is the kind of reassurance that only costs you once.
private struct WalkReportCard: View {
    let summary: WalkSummary
    let dismiss: () -> Void

    /// Long enough to read four lines without hurrying, short enough not to stay in the
    /// way of someone doing something else.
    private static let linger: Duration = .seconds(8)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.changedNothing
                  ? "checkmark.circle.fill" : "sparkles")
                .foregroundStyle(.tint)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline)
                    .font(.subheadline.weight(.semibold))
                ForEach(summary.details, id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        // Upwards: the gesture goes in the direction the card came from, and it cannot be
        // mistaken for scrolling whatever it covers.
        .gesture(DragGesture(minimumDistance: 12).onEnded { move in
            if move.translation.height < 0 { dismiss() }
        })
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: summary) {
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            dismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Toucher pour fermer")
    }
}

/// Reuses `pair()` as is: it already knows how to discover the box, wait for the ✓, store
/// the token in the keychain and validate with a read. Nothing to rewrite, and a single way
/// to pair in the whole project.
private struct ReassociateSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                CageMark.Filled(height: 84).foregroundStyle(.tint)
                Text("Réassocier Keo")
                    .font(.title2.bold())
                switch store.phase {
                case .waitingForButton:
                    ProgressView()
                    Text("Appuie sur « ✓ » sur l'écran de la Freebox.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                case .discovering:
                    ProgressView()
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                    Button("Réessayer") { Task { await store.pair() } }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Color("OnAccent"))
                case .idle:
                    Text("Keo va demander l'autorisation à la box. Garde-la à portée de main.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Demander l'autorisation") { Task { await store.pair() } }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Color("OnAccent"))
                }
                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        // Closes on its own as soon as authorization is back, whether by ✓ or by iCloud.
        .onChange(of: store.authorizationLost) { _, lost in if !lost { dismiss() } }
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
        // Zero by zero, and only there to find the tab bar from SwiftUI, which offers no
        // handle on it. Whatever is drawn is drawn in the bar itself.
        .background {
            TabBarGlow(running: indexer.state.isRunning).frame(width: 0, height: 0)
        }
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
