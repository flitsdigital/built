import WidgetKit
import SwiftUI

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    private var current: WidgetSnapshot {
        WidgetSnapshot.load() ?? WidgetSnapshot(score: 0, protein: 0, proteinTarget: 120,
                                                trained: false, creatine: false, weighed: false,
                                                slept: false, streak: 0)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snap: current)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snap: current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // ponytail: de app reloadt de widget bij elke wijziging; elk uur verversen is genoeg als fallback
        completion(Timeline(entries: [SnapshotEntry(date: .now, snap: current)],
                            policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct BuiltWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 16) {
                ring
                checks
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if entry.snap.streak > 0 {
                    HStack {
                        Text("🔥 \(entry.snap.streak)")
                            .font(.caption.bold())
                        Spacer()
                    }
                }
                ring
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: Double(entry.snap.score) / 100)
                .stroke(.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(entry.snap.score)")
                    .font(.title2.bold().monospacedDigit())
                Text("/100")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(done: entry.snap.protein >= entry.snap.proteinTarget,
                text: "\(entry.snap.protein)/\(entry.snap.proteinTarget) g eiwit")
            row(done: entry.snap.trained || (entry.snap.restDay ?? false),
                text: (entry.snap.restDay ?? false) && !entry.snap.trained ? "Rustdag" : "Training")
            if entry.snap.showCreatine ?? true {
                row(done: entry.snap.creatine, text: "Creatine")
            }
            row(done: entry.snap.weighed, text: "Gewicht")
            if entry.snap.showSleep ?? true {
                row(done: entry.snap.slept, text: "Slaap")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(done: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(done ? .green : .secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(done ? .secondary : .primary)
        }
    }
}

@main
struct BuiltWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BuiltWidget", provider: SnapshotProvider()) { entry in
            BuiltWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Groei Score")
        .description("Je score en checklist van vandaag.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
