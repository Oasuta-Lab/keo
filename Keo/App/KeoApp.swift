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
                    NavigationStack {
                        BrowserView(client: client,
                                    source: .folder(path: FreeboxClient.rootPath,
                                                    title: store.boxName))
                    }
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
