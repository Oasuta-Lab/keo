import SwiftUI
import WidgetKit

/// The photos of today's date in years gone by.
///
/// `StaticConfiguration`: a day is not something to choose, it is today. This is the only
/// content in the whole widget that is different tomorrow, which is what makes it worth a
/// place on the Home Screen at all.
struct OnThisDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeoOnThisDay", provider: MemoryProvider()) { entry in
            OnThisDayView(entry: entry)
        }
        .configurationDisplayName("Ce jour-là")
        .description("Les photos prises à cette date, les années passées.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Timeline

struct MemoryEntry: TimelineEntry, Sendable {
    let date: Date
    let shots: [Shot]
    /// « 25 octobre », already localised by the app.
    let label: String
    /// What the day really holds, which can exceed the twelve that were rendered.
    let total: Int
    let size: CGSize
    let message: String?

    struct Shot: Identifiable, Sendable {
        var id: URL { file }
        let file: URL
        let year: Int
    }
}

struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        blank(context.displaySize, nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        completion(entries(in: context)[0])
    }

    /// The timeline stops at midnight, because at midnight the answer changes. Everything
    /// else here is for today and only today.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        completion(Timeline(entries: entries(in: context), policy: .after(midnight)))
    }

    private func blank(_ size: CGSize, _ message: String?) -> MemoryEntry {
        MemoryEntry(date: Date(), shots: [], label: "", total: 0, size: size, message: message)
    }

    private func entries(in context: Context) -> [MemoryEntry] {
        let size = context.displaySize
        guard let manifest = WidgetStore.manifest(),
              let directory = WidgetManifest.directory else {
            return [blank(size, "Ouvre Keo pour remplir le widget")]
        }
        // The app renders the memories for the day it last ran. Past midnight they are
        // yesterday's, and showing them under yesterday's label would be a small lie told
        // every morning.
        guard Calendar.current.isDateInToday(manifest.stamped) else {
            return [blank(size, "Ouvre Keo pour les photos d'aujourd'hui")]
        }
        guard let memory = manifest.onThisDay else {
            // Most days of a modest library hold nothing, and that is a fact rather than a
            // failure — so it is said plainly rather than dressed as an error. No date in the
            // sentence: the manifest only carries a label when it carries photos, and
            // formatting one here is the app's job, not the extension's.
            return [blank(size, "Rien ce jour-là dans les années passées")]
        }

        let home = directory.appendingPathComponent(WidgetManifest.dayKey, isDirectory: true)
        let shots = zip(memory.images, memory.years)
            .filter { !$0.0.isEmpty && !$0.0.contains("/") && !$0.0.contains("..") }
            .map { MemoryEntry.Shot(file: home.appendingPathComponent($0.0), year: $0.1) }
        guard !shots.isEmpty else {
            return [blank(size, "Ouvre Keo pour remplir le widget")]
        }

        let start = Date()
        return (0..<WidgetStore.steps).map { step in
            let offset = (step * 4) % shots.count
            return MemoryEntry(date: start.addingTimeInterval(TimeInterval(step) * WidgetStore.stride),
                               shots: Array(shots[offset...] + shots[..<offset]),
                               label: memory.label, total: memory.total,
                               size: size, message: nil)
        }
    }
}

// MARK: - Rendering

struct OnThisDayView: View {
    let entry: MemoryEntry

    @Environment(\.widgetFamily) private var family

    private let gap: CGFloat = 2

    var body: some View {
        content
            .containerBackground(.black, for: .widget)
            .widgetURL(entry.shots.isEmpty ? nil : WidgetManifest.link(day: entry.date))
    }

    @ViewBuilder
    private var content: some View {
        if entry.shots.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text(entry.message ?? "Ouvre Keo pour remplir le widget")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            photos
                .overlay(alignment: .bottom) {
                    Caption(name: entry.label, detail: detail, compact: family == .systemSmall)
                }
        }
    }

    /// Small shows one memory, medium a row of three, large a hero over three — the same
    /// shape as the folder mosaic, but every cell carries its own year, because seeing the
    /// same date ten years apart *is* the content.
    @ViewBuilder
    private var photos: some View {
        switch family {
        case .systemSmall:
            cell(entry.shots[0], side: max(entry.size.width, entry.size.height))
        case .systemLarge:
            VStack(spacing: gap) {
                cell(entry.shots[0], side: entry.size.width)
                strip(Array(entry.shots.dropFirst()), height: entry.size.height * 0.3)
            }
        default:
            strip(entry.shots, height: entry.size.height)
        }
    }

    @ViewBuilder
    private func strip(_ shots: [MemoryEntry.Shot], height: CGFloat) -> some View {
        let count = min(3, shots.count)
        if count > 0 {
            let width = (entry.size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            HStack(spacing: gap) {
                ForEach(shots.prefix(count)) { shot in
                    cell(shot, side: max(width, height))
                }
            }
            .frame(height: height)
        }
    }

    private func cell(_ shot: MemoryEntry.Shot, side: CGFloat) -> some View {
        Photo(file: shot.file, side: side)
            .overlay(alignment: .topLeading) {
                Text(WidgetStore.ago(shot.year, now: entry.date))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
    }

    /// The label already names the day, so the detail says how much of it there is — and only
    /// when more was found than is on screen.
    private var detail: String? {
        guard family != .systemSmall, entry.total > entry.shots.count else { return nil }
        return "\(entry.total.formatted()) photos ce jour-là"
    }
}
