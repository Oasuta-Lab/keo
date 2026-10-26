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
            // Une seule bannière, à la racine, pour une panne qui peut surgir de partout :
            // une grille, la visionneuse, une marche d'indexation, un réveil en arrière-plan.
            // Les vues n'en savent rien et continuent de montrer l'index local.
            //
            // **Avant** les `environmentObject`, et ce n'est pas un détail de mise en forme :
            // le contenu d'un `safeAreaInset` posé après eux n'est pas dans le sous-arbre
            // qu'ils peuplent. La bannière s'affichait, puis `@EnvironmentObject` piégeait au
            // premier appui — « Réessayer » fermait l'app.
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.authorizationLost { AuthorizationBanner() }
            }
            // Flottants plutôt qu'insérés : une marche dure des minutes et traverse tous les
            // écrans, et un bandeau qui pousse le contenu de trois points le fait sauter deux
            // fois par passage. L'un et l'autre se posent au-dessus, et ne déplacent rien.
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
            // Le jeton peut arriver par iCloud pendant que l'app est en arrière-plan, et le
            // trousseau met parfois des minutes. Au retour, on retente en silence.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.retryWithFreshToken()
            }
            // Independent of the Freebox pairing: favourites can come back from iCloud
            // before the box has ever answered.
            .task { await sync.start() }
            // Une demande en attente, toujours : `submit` remplace celle de même identifiant,
            // donc relancer l'app n'en empile pas deux. C'est ce qui permet à Keo d'apprendre
            // qu'un fichier est arrivé sans qu'on ait eu à y penser. Le *handler*, lui, est
            // enregistré dans `init` — voir `PeriodicDiscovery.register`.
            .task { PeriodicDiscovery.schedule() }
            // Le bilan du dernier passage vit dans l'index, pas en mémoire : sans ça, l'écran
            // Indexation et la rangée de l'accueil repartent muets à chaque lancement.
            .task { await indexer.restoreLastPass() }
            .onOpenURL { link = DeepLink($0) }
            // Zero-sized, and the only place a shake is heard. It gives up first responder
            // to any text field that wants it, which is right: while typing, a shake belongs
            // to the field's own undo.
            .background(ShakeCatcher { undoer.undo() })
        }
    }
}


/// Dit la seule panne que le propriétaire doit traiter lui-même, et ce qu'elle veut dire.
///
/// Elle ne couvre pas « la box est hors de portée » : être ailleurs que chez soi est l'état
/// normal de cette app, et tout ce qui est indexé reste consultable. Elle ne paraît que sur un
/// refus **nommé** par la Freebox, qui a survécu à une réouverture de session et à une
/// relecture du trousseau.
///
/// Le premier mot va à l'explication la plus probable, et c'est celle qui a mordu : un autre
/// appareil vient de s'associer, la box ne reconnaît qu'un jeton par application, et le jeton
/// neuf arrive par iCloud quelques minutes plus tard. Appuyer sur ✓ marche aussi, mais
/// révoque à son tour l'autre appareil — autant le dire avant de l'envoyer le faire.
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

/// Ce qu'une marche terminée a changé, dit une fois puis oublié.
///
/// Il ne paraît qu'après une passe **complète**. Une passe interrompue sait ce qu'elle a vu,
/// pas ce qu'elle a manqué, et « Rien de neuf » venant d'une marche qui a atteint quatre
/// dossiers sur huit mille est le genre de réconfort qui ne coûte qu'une fois.
private struct WalkReportCard: View {
    let summary: WalkSummary
    let dismiss: () -> Void

    /// Assez pour lire quatre lignes sans se presser, assez peu pour ne pas rester dans le
    /// chemin de quelqu'un qui fait autre chose.
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
        // Vers le haut : le geste va dans la direction d'où la carte est venue, et il ne peut
        // pas être confondu avec le défilement de ce qu'elle recouvre.
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

/// Réutilise `pair()` tel quel : il sait déjà découvrir la box, attendre le ✓, ranger le jeton
/// dans le trousseau et valider par une lecture. Rien à réécrire, et une seule façon
/// d'associer dans tout le projet.
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
        // Elle se ferme d'elle-même dès que l'autorisation est revenue, par ✓ ou par iCloud.
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
        // Zéro par zéro, et seulement là pour trouver la barre d'onglets depuis SwiftUI, qui
        // n'en donne aucune prise. Ce qui est dessiné l'est dans la barre elle-même.
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
