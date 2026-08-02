import SwiftUI
import SwiftData
import WidgetKit

struct DashboardView: View {
    let profile: Profile
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
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
    @State private var showCheckIn = false
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
    /// Weekdot groeit mee met Dynamic Type, anders past het cijfer er niet in.
    @ScaledMetric(relativeTo: .caption2) private var dotSize: CGFloat = 34
    private let syncStatus = SyncStatus.shared
    private let health = HealthService.shared

    private var cal: Calendar { .current }
    private var today: Date { cal.startOfDay(for: .now) }
    private var isToday: Bool { dayKey(selectedDay) == dayKey(today) }

    /// Eén keer per render opgebouwd en overal doorgegeven. Als computed property zou
    /// hij bij élke aanroep opnieuw over alle tabellen lopen — precies wat we weghalen.
    private func makeIndex() -> DayIndex {
        DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits, habitLogs: habitLogs)
    }

    // MARK: - Dag-gebonden helpers (werken voor elke dag, niet alleen vandaag)
    private func restDayOn(_ day: Date) -> Bool {
        !profile.trainingDays.isEmpty && !profile.trainingDays.contains(cal.component(.weekday, from: day))
    }

    private var customHabitNames: [String] { customHabits.map(\.name) }

    private func scoreOn(_ day: Date, _ idx: DayIndex) -> Int {
        DayCheck.score(day, index: idx, profile: profile, customHabits: customHabitNames)
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

    private func streak(_ idx: DayIndex) -> Int {
        DayCheck.streak(index: idx, profile: profile, customHabits: customHabitNames)
    }

    // MARK: - Streak per habit (🔥5 naast de rij)

    private func streakTrained(_ idx: DayIndex) -> Int { habitStreak { idx.trained($0) || restDayOn($0) } }
    private func streakWeighed(_ idx: DayIndex) -> Int { habitStreak { idx.weighed($0) } }
    private func streakCreatine(_ idx: DayIndex) -> Int { habitStreak { idx.habits($0)?.creatine == true } }
    private func streakSlept(_ idx: DayIndex) -> Int { habitStreak { idx.habits($0)?.sleptEnough == true } }
    private func streakCheckIn(_ idx: DayIndex) -> Int { habitStreak { idx.habits($0)?.checkedIn == true } }
    private func streakCustom(_ name: String, _ idx: DayIndex) -> Int {
        habitStreak { idx.logged(name, on: $0) }
    }

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
        if isVisible { content } else { Color.clear }
    }

    @ViewBuilder private var content: some View {
        // Eén index per render, gedeeld door elke kaart hieronder. Ook `score` en `streak`
        // hangen eraan, zodat de .onChange-vergelijkingen niet opnieuw gaan rekenen.
        let idx = makeIndex()
        let score = scoreOn(today, idx)
        let streak = streak(idx)
        return ScrollView {
            LazyVStack(spacing: 16) {
                entranced(0, header(idx, streak: streak))
                entranced(1, weekCard(idx))
                entranced(2, dayCards(idx))
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
        .task { await health.refreshIfEnabled() }
        .onAppear {
            appeared = true
            writeSnapshot(idx, score: score, streak: streak)
            // Zondag-review: één keer per week, op zondag
            let week = cal.component(.weekOfYear, from: .now) + cal.component(.yearForWeekOfYear, from: .now) * 100
            if cal.component(.weekday, from: .now) == 1, lastReviewWeek != week {
                lastReviewWeek = week
                showWeeklyReview = true
            }
        }
        .onChange(of: score) { writeSnapshot(idx, score: score, streak: streak) }
        .onChange(of: streak) { writeSnapshot(idx, score: score, streak: streak) }
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
            case "checkin":
                selectedTab = 0
                selectedDay = today // check-in gaat altijd over vandaag
                showCheckIn = true
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
        .sheet(isPresented: $showCheckIn) { CheckInSheet(day: selectedDay) }
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

    /// Stipje op het profiel-icoon: er is een fout, óf er is al een dag niets
    /// doorgekomen — dat laatste voelt de gebruiker anders pas op een nieuw toestel.
    private var syncNeedsAttention: Bool {
        syncStatus.lastError != nil || syncStatus.isStale
    }

    private var syncLabel: String {
        if syncStatus.lastError != nil { return "Profiel, synchronisatie-fout" }
        if syncStatus.isStale { return "Profiel, langer dan een dag niet gesynct" }
        return "Profiel"
    }

    private func header(_ idx: DayIndex, streak: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name.isEmpty ? "\(greeting) 👋" : "\(greeting) \(profile.name) 👋")
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    Button { changeDay(by: -1, from: .leading) } label: {
                        Image(systemName: "chevron.left").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Vorige dag")
                    Text((isToday ? Date.now : selectedDay).formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button { changeDay(by: 1, from: .trailing) } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(isToday ? .quaternary : .tertiary)
                    .disabled(isToday)
                    .accessibilityLabel("Volgende dag")
                    if !isToday {
                        Button { selectDay(today) } label: {
                            Text("Vandaag").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                        }
                        .padding(.leading, 2)
                    }
                }
                .buttonStyle(.plain)
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
                    .background(.builtTint(.orange), in: Capsule())
                    .animation(.snappy(duration: 0.25), value: streak)
                }
                NavigationLink {
                    ProfileView(profile: profile)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.crop.circle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        if syncNeedsAttention {
                            // Ring in de achtergrondkleur: zonder die scheiding valt het
                            // stipje weg tegen het profiel-icoon eronder.
                            Circle()
                                .fill(.orange)
                                .frame(width: 11, height: 11)
                                .padding(2)
                                .background(Color(.systemGroupedBackground), in: Circle())
                                .offset(x: 2, y: -2)
                        }
                    }
                    .accessibilityLabel(syncLabel)
                }
            }
        }
        .padding(.top, 8)
    }

    private func writeSnapshot(_ idx: DayIndex, score: Int, streak: Int) {
        let h = idx.habits(today)
        WidgetSnapshot(score: score, protein: idx.protein(today), proteinTarget: profile.proteinTarget,
                       trained: idx.trained(today), creatine: h?.creatine == true,
                       weighed: idx.weighed(today), slept: h?.sleptEnough == true,
                       streak: streak, showCreatine: profile.tracksCreatine, showSleep: profile.tracksSleep,
                       restDay: restDayOn(today), showFood: profile.foodInScore).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func weekCard(_ idx: DayIndex) -> some View {
        card {
            HStack {
                ForEach(weekDays, id: \.self) { day in
                    weekDot(day, idx)
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

    private func weekDot(_ day: Date, _ idx: DayIndex) -> some View {
        let s = scoreOn(day, idx)
        let sel = dayKey(day) == dayKey(selectedDay)
        let isToday = cal.isDateInToday(day)
        return VStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .fontWeight(sel ? .bold : .regular)
                .foregroundStyle(sel || isToday ? .primary : .secondary)
            ZStack {
                if s >= 100 {
                    Circle().fill(.green).frame(width: dotSize, height: dotSize)
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else if s > 0 {
                    ProgressRing(value: Double(s) / 100, lineWidth: 3.5) {
                        Text("\(s)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: dotSize, height: dotSize)
                } else {
                    // Geen ProgressRing op 0: die houdt bewust een minimale trim aan om
                    // vanaf te kunnen animeren, en dat leest hier als "iets gedaan".
                    Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3.5)
                        .frame(width: dotSize, height: dotSize)
                }
                if sel {
                    Circle().strokeBorder(.green, lineWidth: 2).frame(width: dotSize + 6, height: dotSize + 6)
                }
            }
            .frame(width: dotSize + 6, height: dotSize + 6)
            Text(day.formatted(.dateTime.day()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selectDay(day) }
        .animation(.snappy(duration: 0.25), value: sel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month()))
        .accessibilityValue(s >= 100 ? "Perfecte dag" : "\(s) van 100")
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
    }

    /// De dag-gebonden kaarten als één groep, zodat ze samen als een pagina in/uit swipen.
    private func dayCards(_ idx: DayIndex) -> some View {
        VStack(spacing: 16) {
            scoreCard(idx)
            checklistCard(idx)     // habits eerst — dat is de kern
            checkInCard(idx)
            if profile.tracksFood { proteinCard(idx) } // eten is extra
        }
        .id(selectedDay)
        .transition(reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: pageEdge).combined(with: .opacity),
                          removal: .move(edge: pageEdge == .trailing ? .leading : .trailing).combined(with: .opacity)))
        .offset(x: reduceMotion ? 0 : dragX)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: dragX)
    }

    private func scoreCard(_ idx: DayIndex) -> some View {
        let s = scoreOn(selectedDay, idx)
        return card {
            HStack(spacing: 20) {
                ProgressRing(value: Double(s) / 100, lineWidth: 12,
                             tint: AnyShapeStyle(AngularGradient(colors: [.green, .mint, .green], center: .center))) {
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

    private func proteinCard(_ idx: DayIndex) -> some View {
        let remaining = max(profile.proteinTarget - idx.protein(selectedDay), 0)
        let kcal = idx.kcal(selectedDay)
        return Button {
            if swipeActive { return }
            withAnimation(.snappy(duration: 0.3)) { selectedTab = 2 }
        } label: {
            card {
                HStack(spacing: 16) {
                    proteinRing(idx)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(remaining > 0 ? "Nog \(remaining) g te gaan" : "Eiwitdoel gehaald 🎯")
                            .font(.headline)
                        if kcal > 0 {
                            Text("\(kcal) kcal gegeten")
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
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private func checklistCard(_ idx: DayIndex) -> some View {
        let h = idx.habits(selectedDay)
        let trained = idx.trained(selectedDay)
        let restDay = restDayOn(selectedDay)
        return card {
            checkRow(icon: "dumbbell.fill", color: .habitTraining,
                     title: restDay && !trained ? "Rustdag (volgens plan)" : "Training",
                     done: trained || restDay,
                     streak: streakTrained(idx)) { selectedTab = 1 }
            if profile.tracksCreatine {
                Divider()
                checkRow(icon: "pills.fill", color: .habitCreatine, title: "Creatine",
                         done: h?.creatine == true, streak: streakCreatine(idx)) { toggleHabit(\.creatine, idx) }
            }
            Divider()
            checkRow(icon: "scalemass.fill", color: .habitWeight, title: weightRowTitle(idx),
                     done: idx.weighed(selectedDay), streak: streakWeighed(idx)) { showWeightSheet = true }
            if profile.tracksSleep {
                Divider()
                checkRow(icon: "moon.fill", color: .habitSleep, title: sleepText(idx),
                         done: h?.sleptEnough == true,
                         missed: h?.sleepHours != nil && h?.sleptEnough != true,
                         streak: streakSlept(idx)) {
                    showSleepSheet = true
                }
            }
            if let steps = healthSteps(on: selectedDay) {
                Divider()
                checkRowLabel(icon: "figure.walk", color: .habitSteps,
                              title: "\(steps.formatted()) stappen", done: steps >= 8000,
                              streak: habitStreak { (healthSteps(on: $0) ?? 0) >= 8000 })
            }
            Divider()
            NavigationLink {
                DayDetailView(day: selectedDay, profile: profile)
            } label: {
                checkRowLabel(icon: "list.bullet.rectangle", color: .habitJournal, title: "Dagdetails",
                              done: false, navigates: true)
            }
            .buttonStyle(PressableStyle())
            ForEach(customHabits) { habit in
                Divider()
                checkRow(icon: "star.fill", color: .habitCustom, title: habit.name,
                         done: idx.logged(habit.name, on: selectedDay),
                         streak: streakCustom(habit.name, idx)) { toggleCustom(habit.name) }
            }
            Text("Slaaptijden en losse metingen: tik op Dagdetails.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Dag-check-in

    /// Ingevuld = compacte samenvatting; leeg = uitnodiging. De vragen zelf staan in
    /// de drawer, met grote knoppen — één vraag tegelijk leest makkelijker dan vier rijtjes.
    private func checkInCard(_ idx: DayIndex) -> some View {
        let h = idx.habits(selectedDay)
        let answers: [(String, Int)] = [("😵🥱🙂💪⚡️", h?.energy ?? 0), ("😞😕😐🙂😄", h?.mood ?? 0),
                                        ("✅🙂😬😖🥵", h?.soreness ?? 0), ("😌🙂😐😰🤯", h?.stress ?? 0),
                                        ("😴🙂😃", h?.sleepQuality ?? 0)]
        return Button {
            if !swipeActive { showCheckIn = true }
        } label: {
            card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Hoe was je dag?")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            streakBadge(streakCheckIn(idx))
                        }
                        Text(h?.checkedIn == true ? "Tik om aan te passen" : "5 korte vragen · ±20 seconden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if h?.checkedIn == true {
                        HStack(spacing: 3) {
                            ForEach(Array(answers.enumerated()), id: \.offset) { _, a in
                                let icons = Array(a.0.map(String.init))
                                Text(a.1 > 0 ? icons[a.1 - 1] : "·")
                                    .font(.system(size: 17))
                                    .grayscale(a.1 > 0 ? 0 : 1)
                                    .opacity(a.1 > 0 ? 1 : 0.3)
                            }
                        }
                    } else {
                        Text("Start")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.green, in: Capsule())
                    }
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private func healthSteps(on day: Date) -> Int? { health.steps(on: day) }

    private func toggleCustom(_ name: String) {
        let key = dayKey(selectedDay)
        if let log = habitLogs.first(where: { $0.name == name && dayKey($0.date) == key }) {
            context.delete(log)
        } else {
            context.insert(HabitLog(name: name, date: stamp(selectedDay)))
        }
    }

    /// done = gehaald (groen ✓), missed = wel gelogd maar niet gehaald (oranje ⃠), anders open (leeg bolletje).
    private func checkRow(icon: String, color: Color, title: String, done: Bool, missed: Bool = false,
                          streak: Int = 0, action: @escaping () -> Void) -> some View {
        Button { if !swipeActive { action() } } label: {
            checkRowLabel(icon: icon, color: color, title: title, done: done, missed: missed, streak: streak)
        }
        .buttonStyle(PressableStyle())
    }

    private func streakBadge(_ days: Int) -> some View { StreakBadge(days: days) }

    /// `navigates` = geen habit maar een doorverwijzing; dan een chevron i.p.v. een
    /// bolletje, anders leest de rij als iets wat je nog moet afvinken.
    private func checkRowLabel(icon: String, color: Color, title: String, done: Bool, missed: Bool = false,
                               streak: Int = 0, navigates: Bool = false) -> some View {
        HStack(spacing: 12) {
            BuiltIconTile(systemName: icon, color: color)
            Text(title)
                .foregroundStyle(done && !navigates ? .secondary : .primary)
                .strikethrough(done && !navigates, color: .secondary)
                .lineLimit(1)
            streakBadge(streak)
            Spacer()
            if navigates {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: done ? "checkmark.circle.fill" : (missed ? "circle.slash" : "circle"))
                    .font(.title3)
                    .foregroundStyle(done ? .green : (missed ? .orange : .secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: done)
                    .animation(.snappy(duration: 0.2), value: missed)
                    // De staat zit alleen in het bolletje; zonder dit hoor je niet of
                    // de habit al af is.
                    .accessibilityLabel(done ? "Afgevinkt" : (missed ? "Niet gehaald" : "Nog te doen"))
            }
        }
    }

    private func weightRowTitle(_ idx: DayIndex) -> String {
        if let kg = idx.weight(selectedDay) { return "Gewicht: \(kg.kgText) kg" }
        return "Gewicht invullen"
    }

    private func proteinRing(_ idx: DayIndex) -> some View {
        let p = idx.protein(selectedDay)
        return ProgressRing(value: Double(p) / Double(max(profile.proteinTarget, 1))) {
            VStack(spacing: 0) {
                Text("\(p)")
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText())
                Text("van \(profile.proteinTarget) g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eiwit")
        .accessibilityValue("\(p) van \(profile.proteinTarget) gram")
    }

    /// Dunne wrapper: alleen de interne stapeling, de kaartstijl komt uit het design system.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content).builtCard()
    }

    private func sleepText(_ idx: DayIndex) -> String {
        if let h = idx.habits(selectedDay)?.sleepHours { return "\(h.kgText) uur geslapen" }
        return "8 uur slaap"
    }

    private func todayHabitsOrCreate(_ idx: DayIndex) -> DayHabits {
        if let h = idx.habits(selectedDay) { return h }
        let h = DayHabits(date: stamp(selectedDay))
        context.insert(h)
        return h
    }

    private func toggleHabit(_ keyPath: ReferenceWritableKeyPath<DayHabits, Bool>, _ idx: DayIndex) {
        let h = todayHabitsOrCreate(idx)
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
    private var today: DayHabits? { habits.first { dayKey($0.date) == dayKey(day) } }

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
