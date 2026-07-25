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
    @State private var showSleepSheet = false
    @State private var showWeeklyReview = false
    @AppStorage("lastReviewWeek") private var lastReviewWeek = 0
    @State private var appeared = false
    /// Geselecteerde dag op het dashboard; swipe of tik in de week-strip om te wisselen.
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    /// Live horizontale verschuiving tijdens het swipen (volgt de vinger).
    @GestureState private var dragX: CGFloat = 0
    /// Kant waar de nieuwe dag vandaan schuift (spatiaal consistent met de veegrichting).
    @State private var pageEdge: Edge = .trailing
    /// True zolang een horizontale veeg bezig is — blokkeert per ongeluk afvuren van knoppen eronder.
    @State private var swipeActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let syncStatus = SyncStatus.shared

    private var cal: Calendar { .current }
    private var today: Date { cal.startOfDay(for: .now) }
    private var isToday: Bool { cal.isDate(selectedDay, inSameDayAs: today) }

    // MARK: - Dag-gebonden helpers (werken voor elke dag, niet alleen vandaag)
    private func habitsOn(_ day: Date) -> DayHabits? { habits.first { cal.isDate($0.date, inSameDayAs: day) } }
    private func proteinOn(_ day: Date) -> Int { proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.grams).reduce(0, +) }
    private func kcalOn(_ day: Date) -> Int { proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.kcal).reduce(0, +) }
    private func trainedOn(_ day: Date) -> Bool { sets.contains { cal.isDate($0.date, inSameDayAs: day) } }
    private func weightLoggedOn(_ day: Date) -> Bool { weights.contains { cal.isDate($0.date, inSameDayAs: day) } }
    private func restDayOn(_ day: Date) -> Bool {
        !profile.trainingDays.isEmpty && !profile.trainingDays.contains(cal.component(.weekday, from: day))
    }

    /// Vervulling van een dag (0…100), zelfde weging als de Groei Score.
    private func scoreOn(_ day: Date) -> Int {
        var raw = min(30, Int(30.0 * Double(proteinOn(day)) / Double(max(profile.proteinTarget, 1))))
        var maxPoints = 70
        if trainedOn(day) || restDayOn(day) { raw += 25 }
        if weightLoggedOn(day) { raw += 15 }
        let h = habitsOn(day)
        if profile.tracksCreatine {
            maxPoints += 15
            if h?.creatine == true { raw += 15 }
        }
        if profile.tracksSleep {
            maxPoints += 15
            if h?.sleptEnough == true { raw += 15 }
        }
        return Int((Double(raw) / Double(maxPoints) * 100).rounded())
    }

    // Vandaag-waarden voor widget/haptics (los van de geselecteerde dag).
    private var score: Int { scoreOn(today) }

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
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                        sets: sets, trainingDays: profile.trainingDays)
    }

    private var proteinRemaining: Int { max(profile.proteinTarget - proteinOn(selectedDay), 0) }

    /// Page-spring: kort, nauwelijks bounce — leest als een pagina die op z'n plek valt.
    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.1)
    }

    /// Dag wisselen; nooit naar de toekomst, max ~1 jaar terug. `edge` = kant waar de nieuwe dag vandaan komt.
    private func changeDay(by delta: Int, from edge: Edge) {
        let candidate = cal.date(byAdding: .day, value: delta, to: selectedDay) ?? selectedDay
        guard candidate <= today,
              cal.dateComponents([.day], from: candidate, to: today).day ?? 0 <= 365 else { return }
        pageEdge = edge
        withAnimation(pageAnimation) { selectedDay = candidate }
    }

    private func selectDay(_ day: Date) {
        let d = cal.startOfDay(for: day)
        guard d <= today, d != selectedDay else { return }
        pageEdge = d > selectedDay ? .trailing : .leading
        withAnimation(pageAnimation) { selectedDay = d }
    }

    /// Horizontaal swipen door dagen: content volgt de vinger, commit op afstand of flick.
    /// Verticaal scrollen blijft aan de ScrollView (we reageren alleen op horizontaal-dominante drags).
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 15)
            .updating($dragX) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                var dx = value.translation.width
                if isToday && dx < 0 { dx *= 0.25 } // geen toekomst — wrijving i.p.v. harde muur
                state = dx
            }
            .onChanged { value in
                // Zodra het duidelijk een horizontale veeg is: knoppen eronder niet laten afvuren.
                if abs(value.translation.width) > 10, abs(value.translation.width) > abs(value.translation.height) {
                    if !swipeActive { swipeActive = true }
                }
            }
            .onEnded { value in
                defer { if swipeActive { DispatchQueue.main.async { swipeActive = false } } }
                guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                let dist = value.translation.width
                let flick = abs(value.predictedEndTranslation.width) > 200
                guard abs(dist) > 70 || flick else { return } // anders veert 'ie terug (dragX → 0)
                if dist < 0 { changeDay(by: 1, from: .trailing) }  // veeg naar links → nieuwere dag van rechts
                else { changeDay(by: -1, from: .leading) }         // veeg naar rechts → oudere dag van links
            }
    }

    /// Tijdstempel voor een nieuw record op de geselecteerde dag (nu voor vandaag, anders 12:00).
    private func stamp(_ day: Date) -> Date {
        cal.isDateInToday(day) ? .now : (cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day)
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
            VStack(spacing: 16) {
                entranced(0, header)
                entranced(1, weekCard)
                entranced(2, dayCards)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .simultaneousGesture(daySwipe)
        .overlay(alignment: .top) {
            // scroll-edge effect: content vervaagt onder de statusbalk i.p.v. er hard doorheen
            LinearGradient(colors: [Color(.systemGroupedBackground), Color(.systemGroupedBackground).opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            appeared = true
            writeSnapshot()
            // Zondag-review: één keer per week, op zondag
            let week = cal.component(.weekOfYear, from: .now) + cal.component(.yearForWeekOfYear, from: .now) * 100
            if cal.component(.weekday, from: .now) == 1, lastReviewWeek != week {
                lastReviewWeek = week
                showWeeklyReview = true
            }
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
                selectedTab = 2
            case "training":
                selectedTab = 1
            case "review":
                showWeeklyReview = true
            default:
                break
            }
            Notifier.shared.pendingAction = nil
        }
        .sensoryFeedback(.success, trigger: score) { _, new in new == 100 } // succes-haptic alleen op het zeldzame moment
        .sheet(isPresented: $showWeeklyReview) { WeeklyReviewSheet(profile: profile) }
        .sheet(isPresented: $showWeightSheet) { WeightLogSheet(initialDate: selectedDay) }
        .sheet(isPresented: $showSleepSheet) { SleepSheet(day: selectedDay) }
    }

    // MARK: - Kaarten

    /// Eenmalige entree per app-start: fade + 12pt rise, 50ms stagger.
    /// Bij reduced motion alleen de fade.
    private func entranced(_ index: Int, _ view: some View) -> some View {
        view
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(.easeOut(duration: 0.3).delay(Double(index) * 0.05), value: appeared)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isToday
                     ? (profile.name.isEmpty ? "\(greeting) 👋" : "\(greeting) \(profile.name) 👋")
                     : selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.title2.bold())
                if isToday {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button { selectDay(today) } label: {
                        Label("Terug naar vandaag", systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
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
                    .accessibilityLabel(syncStatus.lastError != nil ? "Profiel, synchronisatie-fout" : "Profiel")
                }
            }
        }
        .padding(.top, 8)
    }

    private func writeSnapshot() {
        let h = habitsOn(today)
        WidgetSnapshot(score: scoreOn(today), protein: proteinOn(today), proteinTarget: profile.proteinTarget,
                       trained: trainedOn(today), creatine: h?.creatine == true,
                       weighed: weightLoggedOn(today), slept: h?.sleptEnough == true,
                       streak: streak, showCreatine: profile.tracksCreatine, showSleep: profile.tracksSleep,
                       restDay: restDayOn(today)).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var weekCard: some View {
        card {
            HStack {
                ForEach(weekDays, id: \.self) { day in
                    weekDot(day)
                }
            }
            Divider()
            HStack {
                Text(weights.count < 2 ? "Log een paar metingen voor je schema-status" : "Je ligt \(onSchedulePct)% op schema")
                Spacer()
                Text("Dag \(profile.daysIn + 1)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func weekDot(_ day: Date) -> some View {
        let s = scoreOn(day)
        let sel = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        return VStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .fontWeight(sel ? .bold : .regular)
                .foregroundStyle(sel || isToday ? .primary : .secondary)
            ZStack {
                Circle().fill(Color(.tertiarySystemFill)).frame(width: 34, height: 34)
                if s >= 100 {
                    Circle().fill(.green).frame(width: 34, height: 34)
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Circle()
                        .trim(from: 0, to: Double(s) / 100)
                        .stroke(.green, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                    if s > 0 {
                        Text("\(s)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if sel {
                    Circle().strokeBorder(.green, lineWidth: 2).frame(width: 40, height: 40)
                }
            }
            .frame(width: 40, height: 40)
            Text(day.formatted(.dateTime.day()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selectDay(day) }
        .animation(.snappy(duration: 0.25), value: sel)
    }

    /// De dag-gebonden kaarten als één groep, zodat ze samen als een pagina in/uit swipen.
    private var dayCards: some View {
        VStack(spacing: 16) {
            scoreCard
            proteinCard
            checklistCard
        }
        .id(selectedDay)
        .transition(reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: pageEdge).combined(with: .opacity),
                          removal: .move(edge: pageEdge == .trailing ? .leading : .trailing).combined(with: .opacity)))
        .offset(x: reduceMotion ? 0 : dragX)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: dragX)
    }

    private var scoreCard: some View {
        let s = scoreOn(selectedDay)
        return card {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: Double(s) / 100)
                        .stroke(
                            AngularGradient(colors: [.green, .mint, .green], center: .center),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(s)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("/100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .animation(.snappy, value: s)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Groei Score")
                .accessibilityValue("\(s) van 100")

                VStack(alignment: .leading, spacing: 6) {
                    Text("🔥 Groei Score")
                        .font(.headline)
                    Text(s == 100 ? (isToday ? "Perfecte dag! 🏆" : "Perfecte dag 🏆")
                                  : (isToday ? "Nog \(100 - s) punten te pakken" : "\(s)/100 die dag"))
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
        Button {
            if swipeActive { return }
            withAnimation(.snappy(duration: 0.3)) { selectedTab = 2 }
        } label: {
            card {
                HStack(spacing: 16) {
                    proteinRing
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proteinRemaining > 0 ? "Nog \(proteinRemaining) g te gaan" : "Eiwitdoel gehaald 🎯")
                            .font(.headline)
                        if kcalOn(selectedDay) > 0 {
                            Text("\(kcalOn(selectedDay)) kcal gegeten")
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
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private var checklistCard: some View {
        let h = habitsOn(selectedDay)
        return card {
            checkRow(icon: "dumbbell.fill", color: .orange,
                     title: restDayOn(selectedDay) && !trainedOn(selectedDay) ? "Rustdag (volgens plan)" : "Training",
                     done: trainedOn(selectedDay) || restDayOn(selectedDay)) { selectedTab = 1 }
            if profile.tracksCreatine {
                Divider()
                checkRow(icon: "pills.fill", color: .teal, title: "Creatine",
                         done: h?.creatine == true) { toggleHabit(\.creatine) }
            }
            Divider()
            checkRow(icon: "scalemass.fill", color: .purple, title: weightRowTitle,
                     done: weightLoggedOn(selectedDay)) { showWeightSheet = true }
            if profile.tracksSleep {
                Divider()
                checkRow(icon: "moon.fill", color: .indigo, title: sleepText,
                         done: h?.sleptEnough == true,
                         missed: h?.sleepHours != nil && h?.sleptEnough != true) {
                    showSleepSheet = true
                }
            }
            Divider()
            NavigationLink {
                DayDetailView(day: selectedDay, profile: profile)
            } label: {
                checkRowLabel(icon: "book.closed", color: .gray, title: "Journal",
                              done: h?.journal.contains { !$0.text.isEmpty } ?? false)
            }
            .buttonStyle(PressableStyle())
            ForEach(customHabits) { habit in
                Divider()
                checkRow(icon: "star.fill", color: .mint, title: habit.name,
                         done: customDone(habit.name)) { toggleCustom(habit.name) }
            }
            Text("Slaaptijden, kwaliteit en langere notities: tik op Journal.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func customDone(_ name: String) -> Bool {
        habitLogs.contains { $0.name == name && cal.isDate($0.date, inSameDayAs: selectedDay) }
    }

    private func toggleCustom(_ name: String) {
        if let log = habitLogs.first(where: { $0.name == name && cal.isDate($0.date, inSameDayAs: selectedDay) }) {
            context.delete(log)
        } else {
            context.insert(HabitLog(name: name, date: stamp(selectedDay)))
        }
    }

    /// done = gehaald (groen ✓), missed = wel gelogd maar niet gehaald (oranje ⃠), anders open (leeg bolletje).
    private func checkRow(icon: String, color: Color, title: String, done: Bool, missed: Bool = false, action: @escaping () -> Void) -> some View {
        Button { if !swipeActive { action() } } label: {
            checkRowLabel(icon: icon, color: color, title: title, done: done, missed: missed)
        }
        .buttonStyle(PressableStyle())
    }

    private func checkRowLabel(icon: String, color: Color, title: String, done: Bool, missed: Bool = false) -> some View {
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
            Image(systemName: done ? "checkmark.circle.fill" : (missed ? "circle.slash" : "circle"))
                .font(.title3)
                .foregroundStyle(done ? .green : (missed ? .orange : .secondary))
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.2), value: done)
                .animation(.snappy(duration: 0.2), value: missed)
        }
    }

    private var weightRowTitle: String {
        if let w = weights.last(where: { cal.isDate($0.date, inSameDayAs: selectedDay) }) {
            return "Gewicht: \(w.kg.kgText) kg"
        }
        return "Gewicht invullen"
    }

    private var proteinRing: some View {
        let p = proteinOn(selectedDay)
        return ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(1, Double(p) / Double(max(profile.proteinTarget, 1))))
                .stroke(.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(p)")
                    .font(.title2.bold())
                    .contentTransition(.numericText())
                Text("van \(profile.proteinTarget) g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .animation(.snappy, value: p)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eiwit")
        .accessibilityValue("\(p) van \(profile.proteinTarget) gram")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var sleepText: String {
        if let h = habitsOn(selectedDay)?.sleepHours { return "\(h.kgText) uur geslapen" }
        return "8 uur slaap"
    }

    private func todayHabitsOrCreate() -> DayHabits {
        if let h = habitsOn(selectedDay) { return h }
        let h = DayHabits(date: stamp(selectedDay))
        context.insert(h)
        return h
    }

    private func toggleHabit(_ keyPath: ReferenceWritableKeyPath<DayHabits, Bool>) {
        let h = todayHabitsOrCreate()
        h[keyPath: keyPath].toggle()
    }
}

/// Snel slaap loggen vanaf het dashboard: tijden staan vooringevuld met je vorige
/// bed-/wektijd, dus meestal is het alleen "Opslaan". Afvinken-zonder-tijden kan ook.
struct SleepSheet: View {
    var day: Date = .now
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DayHabits.date, order: .reverse) private var habits: [DayHabits]

    @State private var bed = Date.now
    @State private var wake = Date.now
    @State private var quality = 0
    @State private var loaded = false

    private var cal: Calendar { .current }
    private var today: DayHabits? { habits.first { cal.isDate($0.date, inSameDayAs: day) } }

    private var hours: Double {
        var h = wake.timeIntervalSince(bed) / 3600
        if h < 0 { h += 24 }
        return h
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Naar bed", selection: $bed, displayedComponents: .hourAndMinute)
                    DatePicker("Wakker", selection: $wake, displayedComponents: .hourAndMinute)
                    LabeledContent("Geslapen") {
                        Text("\(hours.kgText) uur\(hours >= 8 ? " ✓" : " · doel 8 u")")
                            .foregroundStyle(hours >= 8 ? .green : .secondary)
                    }
                }
                Section("Hoe geslapen?") {
                    Picker("Kwaliteit", selection: $quality) {
                        Text("—").tag(0)
                        Text("😴").tag(1)
                        Text("🙂").tag(2)
                        Text("😃").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    if today?.sleptEnough == true {
                        Button("Vinkje weghalen", role: .destructive) {
                            todayOrCreate().sleptEnough = false
                            dismiss()
                        }
                    } else {
                        Button("Alleen afvinken (8+ uur, zonder tijden)") {
                            todayOrCreate().sleptEnough = true
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Slaap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") { save() }
                }
            }
        }
        .presentationDetents([.height(420)])
        .onAppear { prefill() }
    }

    private func todayOrCreate() -> DayHabits {
        if let today { return today }
        let h = DayHabits(date: cal.isDateInToday(day) ? .now : (cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day))
        context.insert(h)
        return h
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        quality = today?.sleepQuality ?? 0
        // vandaag al tijden? die. Anders: de klok-tijden van je laatste ingevulde nacht.
        let source = (today?.bedTime != nil && today?.wakeTime != nil)
            ? today
            : habits.first { $0.bedTime != nil && $0.wakeTime != nil }
        let bedComps = source?.bedTime.map { cal.dateComponents([.hour, .minute], from: $0) }
        let wakeComps = source?.wakeTime.map { cal.dateComponents([.hour, .minute], from: $0) }
        bed = cal.date(bySettingHour: bedComps?.hour ?? 23, minute: bedComps?.minute ?? 0, second: 0, of: day) ?? day
        wake = cal.date(bySettingHour: wakeComps?.hour ?? 7, minute: wakeComps?.minute ?? 0, second: 0, of: day) ?? day
    }

    private func save() {
        let record = todayOrCreate()
        record.bedTime = bed
        record.wakeTime = wake
        record.sleepQuality = quality
        record.sleptEnough = hours >= 8
        dismiss()
    }
}
