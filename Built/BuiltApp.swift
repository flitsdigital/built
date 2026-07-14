import SwiftUI
import SwiftData

@main
struct BuiltApp: App {
    init() {
        Notifier.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.green) // ponytail: één accentkleur voor de hele app
                .environment(\.locale, Locale(identifier: "nl_NL")) // app-copy is Nederlands → datums ook
        }
        .modelContainer(for: [Profile.self, WeightEntry.self, Scale.self, ProteinEntry.self, SetEntry.self, DayHabits.self, Routine.self, Meal.self, CustomHabit.self, HabitLog.self, PhotoEntry.self])
    }
}

struct RootView: View {
    @Query private var profiles: [Profile]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var restoring = false
    @AppStorage("restSeconds") private var restSeconds = 120
    private let workoutStatus = WorkoutStatus.shared

    init() {
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        content
            .task {
                Notifier.shared.context = context
                guard Sync.isConfigured else { return }
                // Bepaal veilig of auto-push mag; haalt bij een lege install eerst alles op
                restoring = profiles.isEmpty
                await Sync.bootstrap(context)
                restoring = false
                Sync.start(context)
            }
            .onChange(of: scenePhase) { _, phase in
                Sync.appActive = phase == .active
                if phase == .background {
                    Notifier.shared.refresh() // meldingen herplannen op actuele staat
                    Task { await Sync.pushIfChanged(context) }
                }
            }
    }

    private func restLabel(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    @ViewBuilder private var content: some View {
        if restoring, profiles.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Data ophalen…")
                    .font(.headline)
                Text("Even geduld, je gegevens komen van de server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let profile = profiles.first {
            TabView(selection: $tab) {
                NavigationStack { DashboardView(profile: profile, selectedTab: $tab).tabBarClearance() }
                    .tag(0)
                NavigationStack { TrainingView(profile: profile).tabBarClearance() }
                    .tag(1)
                NavigationStack { WeightView(profile: profile).tabBarClearance() }
                    .tag(2)
                NavigationStack { InsightsView(profile: profile).tabBarClearance() }
                    .tag(3)
                NavigationStack { JournalView(profile: profile).tabBarClearance() }
                    .tag(4)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let restEnd = workoutStatus.restEndsAt, restEnd > .now {
                        HStack(spacing: 10) {
                            Menu {
                                ForEach([60, 90, 120, 180], id: \.self) { s in
                                    Button {
                                        restSeconds = s
                                    } label: {
                                        if restSeconds == s {
                                            Label(restLabel(s), systemImage: "checkmark")
                                        } else {
                                            Text(restLabel(s))
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "timer").foregroundStyle(.green)
                            }
                            Text(timerInterval: Date.now...restEnd, countsDown: true)
                                .font(.footnote.bold().monospacedDigit())
                            Button("+15s") { workoutStatus.startRest(until: restEnd.addingTimeInterval(15)) }
                                .font(.caption.bold())
                            Button("Skip") { workoutStatus.stopRest() }
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.green.opacity(0.4), lineWidth: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let started = workoutStatus.startedAt, tab != 1 {
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { tab = 1 }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "dumbbell.fill")
                                Text("Training bezig")
                                    .font(.footnote.bold())
                                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.green.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(PressableStyle())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    FloatingTabBar(selection: $tab)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .animation(.snappy(duration: 0.3), value: workoutStatus.startedAt)
                .animation(.snappy(duration: 0.3), value: workoutStatus.restEndsAt)
                .sensoryFeedback(.success, trigger: workoutStatus.restFired)
            }
        } else {
            OnboardingView()
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: Int
    @Namespace private var pill

    private let items: [(icon: String, label: String)] = [
        ("flame.fill", "Vandaag"),
        ("dumbbell.fill", "Training"),
        ("chart.line.uptrend.xyaxis", "Gewicht"),
        ("sparkles", "Inzicht"),
        ("book.fill", "Logboek"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let selected = selection == i
                Button {
                    withAnimation(.smooth(duration: 0.25)) { // reposition zonder momentum → geen bounce
                        selection = i
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: items[i].icon)
                        if selected {
                            Text(items[i].label)
                                .font(.footnote.bold())
                                .fixedSize()
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, selected ? 14 : 10)
                    .padding(.vertical, 10)
                    .background {
                        if selected {
                            // ponytail: matchedGeometry laat de pill tussen tabs glijden
                            Capsule()
                                .fill(.green.opacity(0.18))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// Houdt onderaan ruimte vrij voor de zwevende tab bar; content scrollt er wel onderdoor.
    func tabBarClearance() -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
    }
}

/// Press-feedback: subtiel (0.97), snel, ease-out — voelbaar maar onzichtbaar.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97 // grote vlakken krijgen 0.985 — voelbaar, niet zichtbaar

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
