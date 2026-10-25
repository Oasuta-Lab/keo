import AVKit
import Combine
import QuickLook
import SwiftUI

struct ViewerView: View {
    let client: FreeboxClient
    let items: [Item]
    /// The hidden `.MOV` of each Live Photo, by the still it belongs to.
    let companions: [Item.ID: Item]
    /// Reported back so the grid knows which cell to fly home to, and scrolls it into view.
    @Binding var anchor: Item.ID?

    @EnvironmentObject private var downloader: Downloader
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: Item.ID?
    @State private var drag: CGSize = .zero
    /// Pinched in, the scroll view owns the pan — stay out of its way.
    @State private var zoomed = false
    @State private var favourite = false
    @State private var hasNote = false
    @State private var annotating: Item?
    /// Lives here and not in the page: the control that drives it sits in the bottom
    /// bar, which the page does not own.
    @State private var livePlaying = false
    @Namespace private var glassSpace
    /// Counts taps, not the flag: paging also rewrites `favourite`, and swiping between a
    /// favourite and a plain photo must not buzz.
    @State private var favouriteTaps = 0
    @State private var collections: [IndexStore.Collection] = []
    @State private var choosingCollection = false
    /// Capture dates discovered while opening a file, keyed by path.
    @State private var captured: [Item.ID: Date] = [:]

    /// The dismiss drag rewrites `drag` on every touch frame and the body reads `current`
    /// several times per pass; a linear scan of a 14 600-item folder does not fit in a frame.
    private let indexByID: [Item.ID: Int]

    init(client: FreeboxClient, items: [Item], companions: [Item.ID: Item] = [:],
         start: Item, anchor: Binding<Item.ID?>) {
        self.client = client
        self.items = items
        self.companions = companions
        _anchor = anchor
        indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        _currentID = State(initialValue: start.id)
    }

    private var current: Item? {
        guard let currentID, let index = indexByID[currentID] else { return items.first }
        return items[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
                .offset(y: drag.height)
                .scaleEffect(shrink)
                .simultaneousGesture(dismissDrag)
        }
        .overlay(alignment: .top) { chrome.opacity(1 - progress) }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                DownloadBar(downloader: downloader)
                    .frame(maxWidth: 420)
                actionBar
            }
            // The whole stack fades with the dismiss drag. The progress bar used to be
            // exempt, which left an opaque strip hanging under a photo already shrinking
            // towards its grid cell, and broke the hand-off to the zoom transition.
            .opacity(1 - progress)
            .padding(.bottom, 4)
        }
        .sheet(item: $downloader.share) { payload in
            ShareSheet(urls: payload.urls)
        }
        .sheet(item: $annotating) { item in
            NoteEditor(item: item) { body in hasNote = !body.isEmpty }
        }
        .confirmationDialog("Ajouter à une collection", isPresented: $choosingCollection,
                            titleVisibility: .visible) {
            ForEach(collections) { collection in
                Button(collection.name) { add(to: collection) }
            }
            Button("Annuler", role: .cancel) {}
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: favouriteTaps)
        .task { collections = (try? await IndexStore.shared.collections()) ?? [] }
        // The heart reflects the photo on screen, so it has to follow the paging.
        // Paging moves the cell the grid will zoom back to.
        .onChange(of: currentID) { _, now in
            anchor = now
            // Paging away must not leave a video running behind the next photo.
            livePlaying = false
        }
        .task(id: currentID) {
            guard let current else { return }
            favourite = (try? await IndexStore.shared.isFavourite(current)) ?? false
            hasNote = (try? await IndexStore.shared.note(on: current)) != nil
        }
        .statusBarHidden()
    }

    private func toggleFavourite() {
        guard let current else { return }
        let next = !favourite
        favourite = next
        favouriteTaps += 1
        Task { try? await IndexStore.shared.setFavourite([current], next) }
    }

    private func add(to collection: IndexStore.Collection) {
        guard let current else { return }
        Task { try? await IndexStore.shared.setMembership([current], in: collection.id, true) }
    }

    /// A paging `ScrollView` rather than `TabView`: a page-style TabView keeps structural
    /// identity for every element, which collapses on a library of thousands.
    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    Page(item: item, client: client, live: companions[item.id],
                         playing: item.id == currentID ? $livePlaying : .constant(false),
                         zoomed: $zoomed, onCaptureDate: { captured[item.id] = $0 })
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed)
        .ignoresSafeArea()
    }

    private var caption: MediaDate? {
        guard let current else { return nil }
        return MediaDate(capture: captured[current.id] ?? current.captureDate,
                         modification: current.modified)
    }

    /// Top: only what must not be thumb-reachable — closing, and knowing what you are looking at.
    private var chrome: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Glyph("xmark") }
                .accessibilityLabel("Fermer")

            Spacer(minLength: 0)

            if let current {
                VStack(spacing: 1) {
                    Text(current.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caption {
                        Text(caption.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            // Balances the close button so the caption stays centred.
            Glyph("xmark").opacity(0).allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
    }

    /// Bottom: everything you actually do, within thumb reach.
    ///
    /// Four actions in one capsule, and the Live control detached in its own bubble. The
    /// previous row of five identical circles read as clutter and its order was simply the
    /// order the features were built in — which put the heart, the most frequent action and
    /// the only one with a haptic, at the hardest reach for a thumb.
    ///
    /// Weight falls from left to right. Slot one moves bytes off the NAS: slow, deliberate,
    /// leaves the app, so it sits where the eye starts and the thumb arrives last. Slots two
    /// to four all write to Keo's own index — note, collection, favourite — and rise in
    /// frequency towards the thumb. Live is in none of those families: it changes what is on
    /// screen, not what is recorded, so it is not in the group at all.
    private var actionBar: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 20) { barRow(morphing: true) }
            } else {
                barRow(morphing: false)
            }
        }
        // Inert on an iPhone. On an iPad it is the whole strategy: the cluster stays a
        // compact bottom-centre object instead of five glyphs scattered across 1 000 points,
        // and the Live bubble stays beside it rather than a hand-span away.
        .frame(maxWidth: 560)
    }

    private var hasLive: Bool {
        guard let current else { return false }
        return companions[current.id] != nil
    }

    private func barRow(morphing: Bool) -> some View {
        cluster
            .modifier(BarSurface(shape: AnyShape(Capsule()), morphing: morphing,
                                 id: "cluster", in: glassSpace))
            .frame(maxWidth: .infinity)
            // An overlay is positioned, not laid out against its siblings, so the bubble
            // appearing cannot move the capsule. The no-shift rule stops being a discipline
            // someone has to remember — the ghost `Color.clear` slot it replaces — and
            // becomes a property of the geometry.
            .overlay(alignment: .trailing) {
                if hasLive {
                    liveButton
                        .modifier(BarSurface(shape: AnyShape(Circle()), morphing: morphing,
                                             id: "live", in: glassSpace))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: hasLive)
            .padding(.horizontal, 16)
    }

    private var cluster: some View {
        HStack(spacing: 0) {
            Menu {
                if let current {
                    Button("Partager", systemImage: "square.and.arrow.up") {
                        downloader.save([current], from: client, to: .share)
                    }
                    if current.isMedia {
                        Button("Enregistrer dans Photos", systemImage: "photo.badge.arrow.down") {
                            downloader.save([current], from: client, to: .photos)
                        }
                    }
                }
            } label: {
                // Up, not down: the glyph has to cover "Partager" as well, and the up arrow
                // is the iOS convention for "this leaves the app". A download arrow promised
                // one of the two items and hid the other.
                ActionGlyph("square.and.arrow.up")
            }
            .disabled(downloader.isRunning)
            .accessibilityLabel("Enregistrer ou partager")

            Button { annotating = current } label: {
                // One glyph in both states. `text.quote` against `text.quote.rtl` is an
                // illegible distinction at this size; the tint says it, as it does for the
                // heart. State is colour, identity is shape, everywhere in this bar.
                ActionGlyph("text.quote", on: hasNote)
            }
            .accessibilityLabel("Note")
            .accessibilityValue(hasNote ? "Présente" : "Aucune")

            Button { choosingCollection = true } label: {
                ActionGlyph("square.stack")
            }
            .accessibilityLabel("Ajouter à une collection")

            Button { toggleFavourite() } label: {
                ActionGlyph(favourite ? "heart.fill" : "heart", on: favourite)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Favori")
            .accessibilityValue(favourite ? "Oui" : "Non")
        }
        .padding(.horizontal, 6)
        .disabled(current == nil)
    }

    /// Never `livephoto.slash`: in Photos that glyph means "Live effect disabled", a
    /// different verb, and borrowing it to mean "stop" teaches the wrong thing. The identity
    /// stays constant and the running state is drawn — tinted, with the ring shimmering.
    private var liveButton: some View {
        Button { livePlaying.toggle() } label: {
            Image(systemName: "livephoto")
                .font(.title3.weight(.medium))
                .foregroundStyle(livePlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                .symbolEffect(.variableColor.iterative, isActive: livePlaying)
                // One dip as you page onto a Live Photo. That is the announcement the
                // deleted "LIVE" pill used to make, without a second thing on screen.
                .symbolEffect(.bounce, value: currentID)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .accessibilityLabel(livePlaying ? "Arrêter la vidéo live" : "Jouer la vidéo live")
    }

    // MARK: Swipe to dismiss

    /// How far along the dismiss we are, 0 to 1.
    private var progress: Double { min(abs(drag.height) / 220, 1) }
    private var shrink: Double { 1 - progress * 0.12 }

    /// `simultaneousGesture` so the horizontal paging keeps working; the dominant axis wins.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !zoomed,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !zoomed, drag != .zero else { return }
                if value.translation.height > 140 || value.predictedEndTranslation.height > 400 {
                    // Hand the photo back at its natural frame first: the zoom transition
                    // animates from what it is given, and a frame already shrunk by the drag
                    // makes it start from the wrong size.
                    drag = .zero
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero }
                }
            }
    }
}

/// A bare monochrome glyph in a hit slot wider than it looks. Tint carries state, shape
/// carries identity, and the surface belongs to the group rather than to each button —
/// per-button glass is what made five circles read as clutter.
private struct ActionGlyph: View {
    let name: String
    var on = false

    init(_ name: String, on: Bool = false) {
        self.name = name
        self.on = on
    }

    var body: some View {
        Image(systemName: name)
            .font(.title3.weight(.medium))
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
            .frame(width: 48, height: 56)
            .contentShape(Rectangle())
    }
}

/// Liquid Glass on iOS 26, the same geometry in material below it. `glassEffectID` lets the
/// Live bubble morph out of the capsule instead of popping into existence.
private struct BarSurface: ViewModifier {
    let shape: AnyShape
    let morphing: Bool
    let id: String
    let space: Namespace.ID

    init(shape: AnyShape, morphing: Bool, id: String, in space: Namespace.ID) {
        self.shape = shape
        self.morphing = morphing
        self.id = id
        self.space = space
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), morphing {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: space)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct Glyph: View {
    let name: String
    let large: Bool

    /// 44 pt is the floor Apple's guidelines set for a tap target; the small variant sat at
    /// about 37. The bottom actions get more than that — they are the ones you reach for.
    init(_ name: String, large: Bool = false) {
        self.name = name
        self.large = large
    }

    var body: some View {
        Image(systemName: name)
            .font(large ? .title2.weight(.medium) : .body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: large ? 30 : 20, height: large ? 30 : 20)
            .padding(large ? 15 : 12)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}

// MARK: - Pages

private struct Page: View {
    let item: Item
    let client: FreeboxClient
    /// The video half, when this still is a Live Photo.
    let live: Item?
    @Binding var playing: Bool
    @Binding var zoomed: Bool
    let onCaptureDate: (Date) -> Void

    var body: some View {
        switch item.kind {
        case .video:
            VideoPage(item: item, client: client, onCaptureDate: onCaptureDate)
        case .other:
            DocumentPage(item: item, client: client)
        default:
            ImagePage(item: item, client: client, live: live, playing: $playing,
                      zoomed: $zoomed, onCaptureDate: onCaptureDate)
        }
    }
}

private struct ImagePage: View {
    let item: Item
    let client: FreeboxClient
    let live: Item?
    @Binding var playing: Bool
    @Binding var zoomed: Bool
    let onCaptureDate: (Date) -> Void

    @State private var image: UIImage?
    @State private var sharp = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, zoomed: $zoomed)
                    .opacity(playing ? 0 : 1)
                if let live, playing {
                    LivePlayback(item: live, client: client) { playing = false }
                }
            } else if failed {
                ContentUnavailableView("Image illisible", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView().tint(.white)
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playing) { _, now in now }
        .task(id: item.path) {
            // The grid thumbnail first so the page is never blank, then the real thing.
            if image == nil,
               let preview = await ThumbnailPipeline.shared.thumbnail(for: item, client: client) {
                image = preview
            }
            guard !sharp, !Task.isCancelled else { return }

            // Streamed to disk and decoded from the file: a 50 MP original never becomes a Data.
            guard let file = try? await client.download(item.path) else {
                failed = image == nil
                return
            }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

            // The full file is already here, so the real shooting date is free to read.
            if let taken = ImageDecoding.captureDate(fileAt: file) { onCaptureDate(taken) }

            // ponytail: 3000 px cap keeps a big scan off the memory ceiling; raise it if you
            // routinely pinch deeper than that.
            if let full = ImageDecoding.downsample(fileAt: file, maxPixel: 3000) {
                guard !Task.isCancelled else { return }
                image = full
                sharp = true
            }
        }
    }
}

private struct VideoPage: View {
    let item: Item
    let client: FreeboxClient
    let onCaptureDate: (Date) -> Void

    @State private var source: AuthenticatedAsset?   // owns the resource loader
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let failure {
                ContentUnavailableView("Lecture impossible", systemImage: "play.slash",
                                       description: Text(failure))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.path) {
            guard player == nil else { return }
            do {
                let authenticated = AuthenticatedAsset(source: try await client.videoSource(item.path))
                let playerItem = AVPlayerItem(asset: authenticated.asset)
                let player = AVPlayer(playerItem: playerItem)

                self.source = authenticated
                self.player = player
                player.play()

                if let stamp = try? await authenticated.asset.load(.creationDate),
                   let taken = try? await stamp.load(.dateValue) {
                    onCaptureDate(taken)
                }

                await reportFailure(of: playerItem)
            } catch {
                failure = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }

    /// Without this a broken stream just spins forever with nothing to go on.
    private func reportFailure(of playerItem: AVPlayerItem) async {
        for await status in playerItem.publisher(for: \.status).values {
            switch status {
            case .failed:
                failure = playerItem.error?.localizedDescription ?? "Le flux n'a pas pu être lu."
                player = nil
                return
            case .readyToPlay:
                return
            default:
                continue
            }
        }
    }
}

private struct DocumentPage: View {
    let item: Item
    let client: FreeboxClient

    @State private var local: URL?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let local {
                QuickLookView(url: local)
            } else if failed {
                ContentUnavailableView("Téléchargement impossible", systemImage: "doc.badge.ellipsis")
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.path) {
            do { local = try await client.download(item.path) } catch { failed = true }
        }
    }
}

// MARK: - UIKit bridges

/// UIScrollView does pinch, pan, momentum and double-tap zoom better than anything hand-rolled.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        bind(context.coordinator)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        bind(context.coordinator)
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        scrollView.setZoomScale(1, animated: false)
    }

    private func bind(_ coordinator: Coordinator) {
        coordinator.onZoom = { zoomed in
            // Deferred: UIScrollView reports this mid-layout, SwiftUI dislikes that.
            DispatchQueue.main.async { self.zoomed = zoomed }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onZoom: ((Bool) -> Void)?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoom?(scrollView.zoomScale > 1.01)
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                scrollView.zoom(to: CGRect(x: point.x - size.width / 6, y: point.y - size.height / 6,
                                           width: size.width / 3, height: size.height / 3),
                                animated: true)
            }
        }
    }
}

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url as NSURL
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url as NSURL) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: NSURL
        init(url: NSURL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { url }
    }
}


/// Plays the hidden half of a Live Photo once, then hands the still back.
///
/// Reuses `AuthenticatedAsset` for the same reason the video page does:
/// `AVURLAssetHTTPHeaderFieldsKey` is undocumented and ignored, so the session token has to
/// ride in through a resource loader or the box answers 403.
private struct LivePlayback: View {
    let item: Item
    let client: FreeboxClient
    let onEnd: () -> Void

    @State private var source: AuthenticatedAsset?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .allowsHitTesting(false)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            do {
                let authenticated = AuthenticatedAsset(source: try await client
                    .videoSource(item.path))
                let player = AVPlayer(playerItem: AVPlayerItem(asset: authenticated.asset))
                // Muted: a Live Photo is three seconds of ambient noise, and Photos plays
                // them silently until you ask otherwise.
                player.isMuted = true
                source = authenticated
                self.player = player
                player.play()
            } catch {
                // A companion that will not load is not worth an error screen — the still is
                // still on display behind, which is what the user came for.
                onEnd()
            }
        }
        .onDisappear { player?.pause() }
        .task(id: player == nil) {
            guard let player else { return }
            // One pass, then back to the still, exactly like letting go in Photos.
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification) {
                _ = player
                onEnd()
                break
            }
        }
    }
}
