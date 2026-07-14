import SwiftUI
import SwiftData
import WidgetKit

struct DashboardView: View {
    let profile: Profile
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]
    @Query(sort: \Meal.createdAt) private var meals: [Meal]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query private var habitLogs: [HabitLog]

    @State private var showWeightSheet = false
    @State private var showProteinSheet = false
    @State private var showNoteAlert = false
    @State private var noteInput = ""
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let syncStatus = SyncStatus.shared

    private var cal: Calendar { .current }
    private var todayProtein: Int { proteins.filter { cal.isDateInToday($0.date) }.map(\.grams).reduce(0, +) }
    private var todayKcal: Int { proteins.filter { cal.isDateInToday($0.date) }.map(\.kcal).reduce(0, +) }
    private var trainedToday: Bool { sets.contains { cal.isDateInToday($0.date) } }
    private var weightLoggedToday: Bool { weights.contains { cal.isDateInToday($0.date) } }
    private var todayHabits: DayHabits? { habits.first { cal.isDateInToday($0.date) } }

    private var score: Int {
        // Genormaliseerd naar 100, ook als creatine/slaap uitgeschakeld zijn
        var raw = min(30, Int(30.0 * Double(todayProtein) / Double(max(profile.proteinTarget, 1))))
        var maxPoints = 70
        if trainedToday { raw += 25 }
        if weightLoggedToday { raw += 15 }
        if profile.tracksCreatine {
            maxPoints += 15
            if todayHabits?.creatine == true { raw += 15 }
        }
        if profile.tracksSleep {
            maxPoints += 15
            if todayHabits?.sleptEnough == true { raw += 15 }
        }
        return Int((Double(raw) / Double(maxPoints) * 100).rounded())
    }

    private var currentWeight: Double {
        weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? profile.startWeight
    }

    private var onSchedulePct: Int {
        guard abs(profile.expectedGain) > 0.05 else { return 100 }
        let pct = (currentWeight - profile.startWeight) / profile.expectedGain * 100
        return max(0, min(150, Int(pct)))
    }

    private var goalProgress: Double {
        let total = profile.goalWeight - profile.startWeight
        guard abs(total) > 0.01 else { return 1 }
        return min(1, max(0, (currentWeight - profile.startWeight) / total))
    }

    private var streak: Int {
        DayCheck.streak(proteins: proteins, weights: weights, habits: habits, target: profile.proteinTarget,
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
    }

    private var proteinRemaining: Int { max(profile.proteinTarget - todayProtein, 0) }

    private var greeting: String {
        switch cal.component(.hour, from: .now) {
        case 6..<12: "Goedemorgen"
        case 12..<18: "Goedemiddag"
        default: "Goedenavond"
        }
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: -6 + $0, to: cal.startOfDay(for: .now)) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                entranced(0, header)
                entranced(1, weekCard)
                entranced(2, scoreCard)
                entranced(3, proteinCard)
                entranced(4, checklistCard)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            appeared = true
            writeSnapshot()
        }
        .onChange(of: score) { writeSnapshot() }
        .onChange(of: streak) { writeSnapshot() }
        .onReceive(Notifier.shared.$pendingAction) { action in
            guard let action else { return }
            switch action {
            case "weigh":
                selectedTab = 0
                showWeightSheet = true
            case "protein":
                selectedTab = 0
                showProteinSheet = true
            case "training":
                selectedTab = 1
            case "review":
                selectedTab = 3
            default:
                break
            }
            Notifier.shared.pendingAction = nil
        }
        .sensoryFeedback(.success, trigger: score)
        .sheet(isPresented: $showWeightSheet) { WeightLogSheet() }
        .sheet(isPresented: $showProteinSheet) { ProteinLogSheet(profile: profile) }
        .alert("Notitie voor vandaag", isPresented: $showNoteAlert) {
            TextField("bijv. Veel energie vandaag", text: $noteInput)
            Button("Opslaan") {
                todayHabitsOrCreate().note = noteInput
                noteInput = ""
            }
            Button("Annuleer", role: .cancel) { noteInput = "" }
        }
    }

    // MARK: - Kaarten

    /// Eenmalige entree per app-start: fade + 12pt rise, 50ms stagger.
    /// Bij reduced motion alleen de fade.
    private func entranced(_ index: Int, _ view: some View) -> some View {
        view
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(.easeOut(duration: 0.35).delay(Double(index) * 0.05), value: appeared)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(greeting) \(profile.name) 👋")
                    .font(.title2.bold())
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if streak > 0 { // ponytail: "🔥 0" demotiveert — pas tonen vanaf 1
                    HStack(spacing: 4) {
                        Text("🔥")
                        Text("\(streak)")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .animation(.snappy(duration: 0.25), value: streak)
                }
                NavigationLink {
                    ProfileView(profile: profile)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.crop.circle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        if syncStatus.lastError != nil {
                            Circle().fill(.orange).frame(width: 10, height: 10)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func writeSnapshot() {
        WidgetSnapshot(score: score, protein: todayProtein, proteinTarget: profile.proteinTarget,
                       trained: trainedToday, creatine: todayHabits?.creatine == true,
                       weighed: weightLoggedToday, slept: todayHabits?.sleptEnough == true,
                       streak: streak, showCreatine: profile.tracksCreatine, showSleep: profile.tracksSleep).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var weekCard: some View {
        card {
            HStack {
                ForEach(weekDays, id: \.self) { day in
                    let perfect = DayCheck.perfect(day, proteins: proteins, weights: weights, habits: habits,
                                                   target: profile.proteinTarget,
                                                   requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
                    VStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(cal.isDateInToday(day) ? .primary : .secondary)
                        ZStack {
                            Circle()
                                .fill(perfect ? Color.green : Color(.tertiarySystemFill))
                                .frame(width: 34, height: 34)
                            if perfect {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            } else if cal.isDateInToday(day) {
                                Circle()
                                    .strokeBorder(.green, lineWidth: 2)
                                    .frame(width: 34, height: 34)
                            }
                        }
                        Text(day.formatted(.dateTime.day()))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Je ligt \(onSchedulePct)% op schema")
                Spacer()
                Text("Dag \(profile.daysIn + 1)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var scoreCard: some View {
        card {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: Double(score) / 100)
                        .stroke(
                            AngularGradient(colors: [.green, .mint, .green], center: .center),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("/100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .animation(.snappy, value: score)

                VStack(alignment: .leading, spacing: 6) {
                    Text("🔥 Groei Score")
                        .font(.headline)
                    Text(score == 100 ? "Perfecte dag! 🏆" : "Nog \(100 - score) punten te pakken")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ProgressView(value: goalProgress)
                        .tint(.green)
                    Text("\(currentWeight.kgText) → \(profile.goalWeight.kgText) kg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var proteinCard: some View {
        Button { showProteinSheet = true } label: {
            card {
                HStack(spacing: 16) {
                    proteinRing
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proteinRemaining > 0 ? "Nog \(proteinRemaining) g te gaan" : "Eiwitdoel gehaald 🎯")
                            .font(.headline)
                        if todayKcal > 0 {
                            Text("\(todayKcal) kcal gegeten")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("Tik om te loggen")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var checklistCard: some View {
        card {
            checkRow(icon: "dumbbell.fill", color: .orange, title: "Training",
                     done: trainedToday) { selectedTab = 1 }
            if profile.tracksCreatine {
                Divider()
                checkRow(icon: "pills.fill", color: .teal, title: "Creatine",
                         done: todayHabits?.creatine == true) { toggleHabit(\.creatine) }
            }
            Divider()
            checkRow(icon: "scalemass.fill", color: .purple, title: weightRowTitle,
                     done: weightLoggedToday) { showWeightSheet = true }
            if profile.tracksSleep {
                Divider()
                checkRow(icon: "moon.fill", color: .indigo, title: sleepText,
                         done: todayHabits?.sleptEnough == true) { toggleHabit(\.sleptEnough) }
            }
            Divider()
            checkRow(icon: "pencil", color: .gray, title: "Notitie",
                     done: !(todayHabits?.note.isEmpty ?? true)) {
                noteInput = todayHabits?.note ?? ""
                showNoteAlert = true
            }
            ForEach(customHabits) { habit in
                Divider()
                checkRow(icon: "star.fill", color: .mint, title: habit.name,
                         done: customDone(habit.name)) { toggleCustom(habit.name) }
            }
            Text("Slaaptijden, kwaliteit en langere notities: Logboek → Vandaag.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func customDone(_ name: String) -> Bool {
        habitLogs.contains { $0.name == name && cal.isDateInToday($0.date) }
    }

    private func toggleCustom(_ name: String) {
        if let log = habitLogs.first(where: { $0.name == name && cal.isDateInToday($0.date) }) {
            context.delete(log)
        } else {
            context.insert(HabitLog(name: name))
        }
    }

    private func checkRow(icon: String, color: Color, title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(color)
                    }
                Text(title)
                    .foregroundStyle(done ? .secondary : .primary)
                    .strikethrough(done, color: .secondary)
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: done)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var weightRowTitle: String {
        if let w = weights.last(where: { cal.isDateInToday($0.date) }) {
            return "Gewicht: \(w.kg.kgText) kg"
        }
        return "Gewicht invullen"
    }

    private var proteinRing: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(1, Double(todayProtein) / Double(max(profile.proteinTarget, 1))))
                .stroke(.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(todayProtein)")
                    .font(.title2.bold())
                    .contentTransition(.numericText())
                Text("van \(profile.proteinTarget) g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .animation(.snappy, value: todayProtein)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var sleepText: String {
        if let h = todayHabits?.sleepHours { return "\(h.kgText) uur geslapen" }
        return "8 uur slaap"
    }

    private func todayHabitsOrCreate() -> DayHabits {
        if let h = todayHabits { return h }
        let h = DayHabits()
        context.insert(h)
        return h
    }

    private func toggleHabit(_ keyPath: ReferenceWritableKeyPath<DayHabits, Bool>) {
        let h = todayHabitsOrCreate()
        h[keyPath: keyPath].toggle()
    }
}
