import AVKit
import QuickLook
import SwiftUI

struct ViewerView: View {
    let client: DAVClient
    let items: [DAVItem]
    @State var current: DAVItem

    @Environment(\.dismiss) private var dismiss

    init(client: DAVClient, items: [DAVItem], start: DAVItem) {
        self.client = client
        self.items = items
        _current = State(initialValue: start)
    }

    var body: some View {
        TabView(selection: $current) {
            ForEach(items) { item in
                Page(item: item, client: client).tag(item)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.horizontal, 16)
        }
        .statusBarHidden()
    }
}

// MARK: - Page

private struct Page: View {
    let item: DAVItem
    let client: DAVClient

    var body: some View {
        switch item.kind {
        case .video: VideoPage(item: item, client: client)
        case .other: DocumentPage(item: item, client: client)
        default: ImagePage(item: item, client: client)
        }
    }
}

private struct ImagePage: View {
    let item: DAVItem
    let client: DAVClient

    @State private var image: UIImage?
    @State private var sharp = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image)
            } else if failed {
                ContentUnavailableView("Image illisible", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.url) {
            // Cached grid thumbnail first so the page is never blank, then the real thing.
            if let preview = await ThumbCache.shared.thumbnail(for: item, client: client) {
                if image == nil { image = preview }
            }
            guard !sharp else { return }
            guard let data = try? await client.data(item.url) else {
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
    let item: DAVItem
    let client: DAVClient

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            guard player == nil else { return }
            let asset = AVURLAsset(url: item.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authHeader]
            ])
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}

private struct DocumentPage: View {
    let item: DAVItem
    let client: DAVClient

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
        .task(id: item.url) {
            do { local = try await client.download(item.url) } catch { failed = true }
        }
    }
}

// MARK: - UIKit bridges

/// UIScrollView does pinch, pan, momentum and double-tap zoom better than anything hand-rolled.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

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

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        scrollView.setZoomScale(1, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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
