import SwiftUI
import SwiftData
import WidgetKit

// Clean-richting (Cal AI): wit/zwart, dunne lijnen, één gigantisch getal als held —
// de belangrijkste open actie ís de pagina. Kleur alleen semantisch (sync-waarschuwing).
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
    @State private var showScoreSheet = false
    @State private var showSleepDetail = false
    @State private var noteInput = ""
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let syncStatus = SyncStatus.shared

    // MARK: - Afgeleiden

    private var cal: Calendar { .current }
    private var todayProtein: Int { proteins.filter { cal.isDateInToday($0.date) }.map(\.grams).reduce(0, +) }
    private var todayKcal: Int { proteins.filter { cal.isDateInToday($0.date) }.map(\.kcal).reduce(0, +) }
    private var trainedToday: Bool { sets.contains { cal.isDateInToday($0.date) } }
    private var weightLoggedToday: Bool { weights.contains { cal.isDateInToday($0.date) } }
    private var todayHabits: DayHabits? { habits.first { cal.isDateInToday($0.date) } }
    private var proteinRemaining: Int { max(profile.proteinTarget - todayProtein, 0) }

    private var todayVolume: Int {
        Int(sets.filter { cal.isDateInToday($0.date) }.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
    }

    private var score: Int {
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

    private var streak: Int {
        DayCheck.streak(proteins: proteins, weights: weights, habits: habits, target: profile.proteinTarget,
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
    }

    private var trendLabel: String {
        guard let t = weights.trendPerWeek else { return "kg" }
        return "kg · \(t >= 0 ? "+" : "")\(t.formatted(.number.precision(.fractionLength(1))))/wk"
    }

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
            VStack(spacing: 24) {
                entranced(0, header)
                entranced(1, hero)
                entranced(2, pillsRow)
                entranced(3, checklist)
                entranced(4, weekFooter)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
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
        .sensoryFeedback(.success, trigger: score) { _, new in new == 100 } // succes-haptic alleen op het zeldzame moment
        .sheet(isPresented: $showWeightSheet) { WeightLogSheet() }
        .sheet(isPresented: $showProteinSheet) { ProteinLogSheet(profile: profile) }
        .sheet(isPresented: $showScoreSheet) { ScoreBreakdownSheet(score: score, parts: scoreParts) }
        .navigationDestination(isPresented: $showSleepDetail) {
            DayDetailView(day: cal.startOfDay(for: .now), profile: profile)
        }
        .alert("Notitie voor vandaag", isPresented: $showNoteAlert) {
            TextField("bijv. Veel energie vandaag", text: $noteInput)
            Button("Opslaan") {
                todayHabitsOrCreate().note = noteInput
                noteInput = ""
            }
            Button("Annuleer", role: .cancel) { noteInput = "" }
        }
    }

    /// Eenmalige entree per app-start: fade + 12pt rise, 50ms stagger. Reduced motion → alleen fade.
    private func entranced(_ index: Int, _ view: some View) -> some View {
        view
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(.easeOut(duration: 0.3).delay(Double(index) * 0.05), value: appeared)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(greeting), \(profile.name)")
                    .font(.headline)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                ProfileView(profile: profile)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.cleanCard)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(profile.name.prefix(1).uppercased())
                                .font(.footnote.bold())
                                .foregroundStyle(.primary)
                        }
                    if syncStatus.lastError != nil {
                        Circle().fill(.orange).frame(width: 9, height: 9)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    // MARK: - Hero: de belangrijkste open actie

    private var heroContent: (value: String, unit: String, sub: String) {
        if proteinRemaining > 0 {
            return ("\(proteinRemaining)", " g", "eiwit te gaan · dan is je dag perfect")
        }
        var open: [String] = []
        if profile.tracksCreatine, todayHabits?.creatine != true { open.append("creatine") }
        if !weightLoggedToday { open.append("wegen") }
        if profile.tracksSleep, todayHabits?.sleptEnough != true { open.append("slaap") }
        if !trainedToday { open.append("training") }
        if open.isEmpty {
            return ("✓", "", "perfecte dag — alles binnen")
        }
        return ("\(open.count)", "", "nog te gaan: \(open.joined(separator: ", "))")
    }

    private var hero: some View {
        Button {
            showProteinSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(heroContent.value)
                            .font(.system(size: 64, weight: .heavy))
                            .tracking(-2)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: heroContent.value)
                        Text(heroContent.unit)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    scoreRing
                }
                Text(heroContent.sub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private var scoreRing: some View {
        ZStack {
            Circle().stroke(Color(.systemFill), lineWidth: 4)
            Circle()
                .trim(from: 0, to: Double(score) / 100)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.caption.bold().monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(width: 44, height: 44)
        .animation(.snappy(duration: 0.3), value: score)
        .accessibilityLabel("Groei Score \(score) van 100")
    }

    // MARK: - Pills

    private var scoreParts: [(name: String, earned: Int, max: Int)] {
        var parts: [(String, Int, Int)] = [
            ("Eiwit", min(30, Int(30.0 * Double(todayProtein) / Double(max(profile.proteinTarget, 1)))), 30),
            ("Training", trainedToday ? 25 : 0, 25),
            ("Gewicht", weightLoggedToday ? 15 : 0, 15),
        ]
        if profile.tracksCreatine { parts.append(("Creatine", todayHabits?.creatine == true ? 15 : 0, 15)) }
        if profile.tracksSleep { parts.append(("Slaap", todayHabits?.sleptEnough == true ? 15 : 0, 15)) }
        return parts
    }

    private var pillsRow: some View {
        HStack(spacing: 10) {
            pill(value: "\(score)", label: "score") { showScoreSheet = true }
            pill(value: currentWeight.kgText, label: trendLabel) { showWeightSheet = true }
            pill(value: streak > 0 ? "🔥 \(streak)" : "—", label: "streak") { selectedTab = 3 }
        }
    }

    private func pill(value: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Color.cleanCard, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(spacing: 0) {
            cleanRow(done: trainedToday, title: "Training",
                     detail: trainedToday ? "\(todayVolume) kg volume" : nil) { selectedTab = 1 }
            if profile.tracksCreatine {
                rowDivider
                cleanRow(done: todayHabits?.creatine == true, title: "Creatine") { toggleHabit(\.creatine) }
            }
            rowDivider
            cleanRow(done: weightLoggedToday, title: "Gewicht",
                     detail: weightLoggedToday ? "\(weights.last { cal.isDateInToday($0.date) }?.kg.kgText ?? "") kg" : nil) {
                showWeightSheet = true
            }
            if profile.tracksSleep {
                rowDivider
                cleanRow(done: todayHabits?.sleptEnough == true, title: "8 uur slaap",
                         detail: todayHabits?.sleepHours.map { "\($0.kgText) u" }) { toggleHabit(\.sleptEnough) }
                    .contextMenu {
                        Button("Slaaptijden & kwaliteit…", systemImage: "moon.zzz") {
                            showSleepDetail = true
                        }
                    }
            }
            rowDivider
            cleanRow(done: !(todayHabits?.note.isEmpty ?? true), title: "Notitie",
                     detail: (todayHabits?.note.isEmpty ?? true) ? nil : todayHabits?.note) {
                noteInput = todayHabits?.note ?? ""
                showNoteAlert = true
            }
            ForEach(customHabits) { habit in
                rowDivider
                cleanRow(done: customDone(habit.name), title: habit.name) { toggleCustom(habit.name) }
            }
        }
        .background(Color.cleanCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 46)
    }

    private func cleanRow(done: Bool, title: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(done ? Color.primary : Color(.separator), lineWidth: 1.5)
                        .background(Circle().fill(done ? Color.primary : .clear))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                    }
                }
                .frame(width: 21, height: 21)
                .animation(.snappy(duration: 0.2), value: done)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(done ? .secondary : .primary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Week-voetnoot

    private var weekFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(weekDays, id: \.self) { day in
                    let perfect = DayCheck.perfect(day, proteins: proteins, weights: weights, habits: habits,
                                                   target: profile.proteinTarget,
                                                   requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
                    Circle()
                        .fill(perfect ? Color.primary : Color(.systemFill))
                        .frame(width: 8, height: 8)
                        .overlay {
                            if cal.isDateInToday(day) {
                                Circle().strokeBorder(Color.primary, lineWidth: 1.5).frame(width: 15, height: 15)
                            }
                        }
                        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))): \(perfect ? "perfect" : "niet perfect")")
                }
            }
            Text("Je ligt \(onSchedulePct)% op schema · dag \(profile.daysIn + 1)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Acties

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

    fileprivate struct ScoreBreakdownSheet: View {
        let score: Int
        let parts: [(name: String, earned: Int, max: Int)]
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 18) {
                VStack(spacing: 2) {
                    Text("\(score)")
                        .font(.system(size: 44, weight: .heavy))
                        .monospacedDigit()
                    Text("Groei Score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(parts, id: \.name) { part in
                        HStack {
                            Image(systemName: part.earned == part.max ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(part.earned == part.max ? .primary : .tertiary)
                            Text(part.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(part.earned) / \(part.max)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        if part.name != parts.last?.name {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(Color.cleanCard, in: RoundedRectangle(cornerRadius: 16))
                Text("Genormaliseerd naar 100 op basis van de habits die je bijhoudt.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .presentationDetents([.height(120 + CGFloat(parts.count) * 46 + 120)])
        }
    }

    private func writeSnapshot() {
        WidgetSnapshot(score: score, protein: todayProtein, proteinTarget: profile.proteinTarget,
                       trained: trainedToday, creatine: todayHabits?.creatine == true,
                       weighed: weightLoggedToday, slept: todayHabits?.sleptEnough == true,
                       streak: streak, showCreatine: profile.tracksCreatine, showSleep: profile.tracksSleep).save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
