import SwiftUI
import WidgetKit

/// The entry point. A `@main WidgetBundle` is what WidgetKit looks for, which is why the
/// Info.plist deliberately carries no `NSExtensionPrincipalClass`.
@main
struct KeoWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeoWidget()
    }
}

struct KeoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeoWidget", provider: Provider()) { _ in
            Text("Keo")
        }
        .configurationDisplayName("Keo")
        .description("Les photos de vos dossiers épinglés.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}
