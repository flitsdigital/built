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
struct BuiltWidgetBundle: WidgetBundle {
    var body: some Widget {
        BuiltWidget()
        WorkoutLiveActivity()
    }
}

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

/// Dynamic Island + lockscreen tijdens een training: verstreken tijd, en bij rust een aflopende timer.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivity.self) { context in
            // Lockscreen-kaart
            HStack(spacing: 14) {
                Image(systemName: "dumbbell.fill")
                    .font(.body.bold())
                    .foregroundStyle(.green)
                    .frame(width: 40, height: 40)
                    .background(.green.opacity(0.15), in: Circle())
                if let end = context.state.restEndsAt {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Rust")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(timerInterval: Date.now...end, countsDown: true)
                                .font(.headline.monospacedDigit())
                        }
                        ProgressView(timerInterval: (context.state.restStartedAt ?? end.addingTimeInterval(-120))...end,
                                     countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(.green)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Training bezig")
                            .font(.footnote.bold())
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(16)
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "dumbbell.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if let end = context.state.restEndsAt {
                            Text(timerInterval: Date.now...end, countsDown: true)
                        } else {
                            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        }
                    }
                    .font(.title2.bold().monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let end = context.state.restEndsAt {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Rust")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(timerInterval: (context.state.restStartedAt ?? end.addingTimeInterval(-120))...end,
                                         countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(.green)
                        }
                    } else {
                        Text("Training bezig")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.resting ? "timer" : "dumbbell.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Group {
                    if let end = context.state.restEndsAt {
                        Text(timerInterval: Date.now...end, countsDown: true)
                            .foregroundStyle(.green)
                    } else {
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.monospacedDigit())
                .frame(maxWidth: 44)
                .multilineTextAlignment(.trailing)
            } minimal: {
                Image(systemName: context.state.resting ? "timer" : "dumbbell.fill")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}
