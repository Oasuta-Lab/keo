import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = Store()
    @StateObject private var downloader = Downloader()

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = store.client {
                    NavigationStack {
                        BrowserView(client: client, path: FreeboxClient.rootPath,
                                    title: store.boxName)
                    }
                } else {
                    ConnectView()
                }
            }
            .environmentObject(store)
            .environmentObject(downloader)
            .preferredColorScheme(.dark)
        }
    }
}
