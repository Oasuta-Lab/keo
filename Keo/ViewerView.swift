import AVKit
import Combine
import QuickLook
import SwiftUI

struct ViewerView: View {
    let client: FreeboxClient
    let items: [Item]
    @State var current: Item

    @EnvironmentObject private var downloader: Downloader
    @Environment(\.dismiss) private var dismiss

    @State private var drag: CGSize = .zero
    /// Pinched in, the scroll view owns the pan — stay out of its way.
    @State private var zoomed = false

    init(client: FreeboxClient, items: [Item], start: Item) {
        self.client = client
        self.items = items
        _current = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(items) { item in
                    Page(item: item, client: client, zoomed: $zoomed).tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: drag.height)
            .scaleEffect(shrink)
            .simultaneousGesture(dismissDrag)
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: { Glyph("xmark") }
                Spacer()
                Menu {
                    if current.kind == .image || current.kind == .video {
                        Button("Enregistrer dans Photos", systemImage: "photo.badge.arrow.down") {
                            downloader.save([current], from: client, to: .photos)
                        }
                    }
                    Button("Partager", systemImage: "square.and.arrow.up") {
                        downloader.save([current], from: client, to: .share)
                    }
                } label: {
                    Glyph("square.and.arrow.down")
                }
                .disabled(downloader.isRunning)
            }
            .padding(.horizontal, 16)
            .opacity(1 - progress)
        }
        .overlay(alignment: .bottom) {
            DownloadBar(downloader: downloader)
        }
        .sheet(item: $downloader.share) { payload in
            ShareSheet(urls: payload.urls)
        }
        .statusBarHidden()
    }

    /// How far along the dismiss we are, 0 to 1.
    private var progress: Double {
        min(abs(drag.height) / 220, 1)
    }

    private var shrink: Double {
        1 - progress * 0.12
    }

    /// `simultaneousGesture` so the page swipe keeps working; the dominant axis decides which wins.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !zoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !zoomed, drag != .zero else { return }
                let flung = value.predictedEndTranslation.height > 400
                if value.translation.height > 140 || flung {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = .zero }
                }
            }
    }
}

private struct Glyph: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
    }
}

// MARK: - Page

private struct Page: View {
    let item: Item
    let client: FreeboxClient
    @Binding var zoomed: Bool

    var body: some View {
        switch item.kind {
        case .video: VideoPage(item: item, client: client)
        case .other: DocumentPage(item: item, client: client)
        default: ImagePage(item: item, client: client, zoomed: $zoomed)
        }
    }
}

private struct ImagePage: View {
    let item: Item
    let client: FreeboxClient
    @Binding var zoomed: Bool

    @State private var image: UIImage?
    @State private var sharp = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, zoomed: $zoomed)
            } else if failed {
                ContentUnavailableView("Image illisible", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.path) {
            // Cached grid thumbnail first so the page is never blank, then the real thing.
            if let preview = await ThumbCache.shared.thumbnail(for: item, client: client) {
                if image == nil { image = preview }
            }
            guard !sharp else { return }
            guard let data = try? await client.data(item.path) else {
                failed = image == nil
                return
            }
            // ponytail: 3000 px cap keeps a 60 MP scan off the memory ceiling; raise if you pinch deep.
            if let full = ThumbCache.downsample(data, maxPixel: 3000) {
                image = full
                sharp = true
            }
        }
    }
}

private struct VideoPage: View {
    let item: Item
    let client: FreeboxClient

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
                let source = try await client.videoAsset(item.path)
                let playerItem = AVPlayerItem(asset: source.asset)
                let player = AVPlayer(playerItem: playerItem)

                self.source = source
                self.player = player
                player.play()

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
                failure = playerItem.error?.localizedDescription
                       ?? "Le flux n'a pas pu être lu."
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
        context.coordinator.onZoom = { zoomed in
            // Deferred: UIScrollView reports this mid-layout, SwiftUI dislikes that.
            DispatchQueue.main.async { self.zoomed = zoomed }
        }

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onZoom = { zoomed in
            DispatchQueue.main.async { self.zoomed = zoomed }
        }
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        scrollView.setZoomScale(1, animated: false)
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
