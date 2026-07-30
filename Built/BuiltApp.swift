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
                // Idem voor de vorm: capsule is een environment-waarde, dus dit geldt
                // voor élke .bordered/.borderedProminent knop, ook in sheets.
                .buttonBorderShape(.capsule)
                .environment(\.locale, Locale(identifier: "nl_NL")) // app-copy is Nederlands → datums ook
        }
        .modelContainer(for: [Profile.self, WeightEntry.self, Scale.self, ProteinEntry.self, SetEntry.self, DayHabits.self, Routine.self, Meal.self, FoodProduct.self, CustomHabit.self, HabitLog.self, PhotoEntry.self, Exercise.self])
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
                #if DEBUG
                // ponytail: screenshot-states forceren via `simctl launch ... -demoRest`
                if ProcessInfo.processInfo.arguments.contains("-demoWorkout") { workoutStatus.startWorkout() }
                if ProcessInfo.processInfo.arguments.contains("-demoEten") { tab = 2 }
                if ProcessInfo.processInfo.arguments.contains("-demoRest") {
                    workoutStatus.startWorkout()
                    workoutStatus.updateContext(exercise: "Bankdrukken", setsDone: 2, setsTotal: 4,
                                                tip: "Vorige keer: 40 kg × 8 — met 45 kg is 6+ reps een PR")
                    workoutStatus.startRest(seconds: 180)
                }
                #endif
                // Opgeslagen training meteen hervatten → "Training bezig"-balk staat er direct
                if workoutStatus.startedAt == nil,
                   let data = UserDefaults.standard.data(forKey: "activeWorkout"),
                   let saved = try? JSONDecoder().decode(SavedWorkout.self, from: data) {
                    workoutStatus.resumeWorkout(at: saved.startedAt)
                }
                workoutStatus.cleanupStaleActivities() // na herstart hangt er anders een oude activity
                Exercise.bootstrap(context) // catalogus vullen + vrije-tekst-namen inhalen
                Notifier.shared.context = context
                guard Sync.isConfigured else { return }
                // Bepaal veilig of auto-push mag; haalt bij een lege install eerst alles op
                restoring = profiles.isEmpty
                await Sync.bootstrap(context)
                restoring = false
                Sync.start(context)
            }
            .onOpenURL { url in
                // Tik op Live Activity of Dynamic Island → direct naar de training
                if url.host() == "training" {
                    withAnimation(.snappy(duration: 0.3)) { tab = 1 }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Sync.appActive = phase == .active
                if phase == .active {
                    workoutStatus.reconcileRestOverride() // +15s/Skip vanaf het lockscreen overnemen
                }
                if phase == .background {
                    Notifier.shared.refresh() // meldingen herplannen op actuele staat
                    Task { await Sync.pushIfChanged(context) }
                }
            }
    }

    private func restLabel(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// Eén tab-pagina; alleen de geselecteerde is zichtbaar en tikbaar (staat blijft behouden).
    @ViewBuilder private func tabPage(_ index: Int, @ViewBuilder _ page: () -> some View) -> some View {
        page()
            .opacity(tab == index ? 1 : 0)
            .allowsHitTesting(tab == index)
            .accessibilityHidden(tab != index)
    }

    /// Rusttimer als brede balk: leeglopende progressielijn (Hevy) + duurmenu, +15s en Skip.
    private func restBar(end: Date) -> some View {
        let start = workoutStatus.restStartedAt ?? end.addingTimeInterval(-Double(max(restSeconds, 30)))
        return HStack(spacing: 12) {
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
                Image(systemName: "timer")
                    .font(.body.bold())
                    .foregroundStyle(.green)
                    .frame(width: 36, height: 36)
                    .background(.builtTint(.green), in: Circle())
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Rust")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .font(.subheadline.bold().monospacedDigit())
                }
                ProgressView(timerInterval: start...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(.green)
            }
            Button("+15s") { workoutStatus.extendRest(by: 15) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .font(.caption.bold())
            Button("Skip") { workoutStatus.stopRest() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: BuiltRadius.floating, style: .continuous))
        .onTapGesture { // knoppen en menu winnen van deze tap
            withAnimation(.snappy(duration: 0.3)) { tab = 1 }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BuiltRadius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BuiltRadius.floating, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(.horizontal, 24)
    }

    /// "Training bezig" als mini-player die terugbrengt naar de training (Ladder-patroon).
    private func workoutBar(started: Date) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { tab = 1 }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dumbbell.fill")
                    .font(.body.bold())
                    .foregroundStyle(.green)
                    .frame(width: 36, height: 36)
                    .background(.builtTint(.green), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Training bezig")
                        .font(.footnote.bold())
                        .foregroundStyle(.primary)
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Verder")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BuiltRadius.floating, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BuiltRadius.floating, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .padding(.horizontal, 24)
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
            // Eigen container i.p.v. TabView: die maakt bij >5 tabs een systeem-"Meer"-tab.
            // Alle stacks blijven leven zodat navigatie-/scrollstaat per tab behouden blijft.
            // isVisible: alleen de actieve tab rekent z'n body door. De views blijven wel
            // in de hiërarchie staan, zodat @State (o.a. de lopende training) blijft leven.
            ZStack {
                tabPage(0) { NavigationStack { DashboardView(profile: profile, isVisible: tab == 0, selectedTab: $tab).tabBarClearance() } }
                tabPage(1) { NavigationStack { TrainingView(profile: profile, isVisible: tab == 1).tabBarClearance() } }
                tabPage(2) { NavigationStack { FoodView(profile: profile, isVisible: tab == 2).tabBarClearance() } }
                tabPage(3) { NavigationStack { WeightView(isVisible: tab == 3, profile: profile).tabBarClearance() } }
                tabPage(4) { NavigationStack { InsightsView(profile: profile, isVisible: tab == 4).tabBarClearance() } }
                tabPage(5) { NavigationStack { JournalView(profile: profile, isVisible: tab == 5).tabBarClearance() } }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    // Eén mini-player-balk (Hevy/Ladder-patroon), nooit twee gestapelde pillen
                    if let restEnd = workoutStatus.restEndsAt, restEnd > .now {
                        restBar(end: restEnd)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let started = workoutStatus.startedAt, tab != 1 {
                        workoutBar(started: started)
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
        ("fork.knife", "Eten"),
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
                                .fill(.builtTint(.green))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[i].label)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
