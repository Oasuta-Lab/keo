import SwiftUI
import WidgetKit

/// How much of the library the index has actually read — on the Lock Screen, and only there.
///
/// Three things had to be true before this was worth building at all, because the research
/// behind the statistics screen rules out numbers you cannot act on, and a widget cannot be
/// tapped into a grid the way a row can.
///
/// 1. **It has to move.** Everything else Keo can count is a property of a fifteen-year
///    photo library that shifts by fractions of a percent a month: a total, a span, a busiest
///    day. The index's own coverage is the only figure that changes by thousands between two
///    glances, and the only one whose change asks something of the owner — open Keo and let
///    it run. Once the library is read it stops moving, which is the honest moment to drop
///    the complication; a « 48 212 fichiers » tile would never have had a moment like that.
/// 2. **It must not pretend to be live.** `Indexer` halts on
///    `didEnterBackgroundNotification`, so the index advances only while the app is open.
///    This is not a progress bar ticking in real time, it is yesterday's finishing line read
///    this morning — which is exactly the question « j'en suis où ? » asks.
/// 3. **It is machinery.** Indexation belongs in one room, and the Home Screen is not that
///    room — it is where « Ce jour-là » and the pinned photos live. A Lock Screen
///    complication is the one slot on the system where a status light is the expected
///    content rather than an admin console leaking onto a gallery.
///
/// No photos, so nothing to decode and nothing to archive: the whole timeline is one entry of
/// five integers, a few kilobytes against the extension's thirty megabytes.
struct CoverageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeoCoverage", provider: CoverageProvider()) { entry in
            CoverageView(entry: entry)
        }
        .configurationDisplayName("Index Keo")
        .description("Ce que Keo a déjà lu de ta bibliothèque.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct CoverageEntry: TimelineEntry, Sendable {
    let date: Date
    /// Nil before the app has ever written a manifest.
    let coverage: WidgetManifest.Coverage?
}

struct CoverageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoverageEntry {
        CoverageEntry(date: Date(), coverage: WidgetManifest.Coverage())
    }

    func getSnapshot(in context: Context, completion: @escaping (CoverageEntry) -> Void) {
        completion(entry())
    }

    /// One entry, renewed daily. Nothing in it is a function of the clock, and the figure
    /// changes only when the app rewrites the manifest — which is followed by
    /// `reloadAllTimelines()`. The daily refresh is a backstop, not the mechanism.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CoverageEntry>) -> Void) {
        completion(Timeline(entries: [entry()],
                            policy: .after(Date().addingTimeInterval(86_400))))
    }

    private func entry() -> CoverageEntry {
        CoverageEntry(date: Date(), coverage: WidgetStore.manifest()?.coverage)
    }
}

// MARK: - Rendering

struct CoverageView: View {
    let entry: CoverageEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(WidgetManifest.statistics)
    }

    @ViewBuilder
    private var content: some View {
        if let coverage = entry.coverage {
            switch family {
            case .accessoryCircular: circular(coverage)
            default: rectangular(coverage)
            }
        } else {
            // Never a broken box and never a zero, which would read as "rien n'est indexé"
            // on a library the widget has simply never been told about.
            Label("Ouvre Keo", systemImage: "square.stack.3d.up")
                .font(.caption2)
                .minimumScaleFactor(0.7)
        }
    }

    private func circular(_ coverage: WidgetManifest.Coverage) -> some View {
        Gauge(value: coverage.fraction) {
            Image(systemName: "square.stack.3d.up")
        } currentValueLabel: {
            // Already floored, so the ring may look full while the text still reads 99 %.
            // The text is the fact; the ring is decoration around it.
            Text(Double(coverage.percent) / 100,
                 format: .percent.precision(.fractionLength(0)))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private func rectangular(_ coverage: WidgetManifest.Coverage) -> some View {
        let (headline, detail) = coverage.lines
        return VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if coverage.isPartial, !coverage.isEmpty {
                ProgressView(value: coverage.fraction)
                    .progressViewStyle(.linear)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
