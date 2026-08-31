import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    let profile: Profile
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query private var habitLogs: [HabitLog]
    @Query private var exercises: [Exercise]

    private var cal: Calendar { .current }

    /// Eén keer per render bouwen en doorgeven — zie `DayIndex`.
    private func makeIndex() -> DayIndex {
        DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits, habitLogs: habitLogs)
    }

    // MARK: - Dag-checks

    private func proteinDone(_ day: Date, _ idx: DayIndex) -> Bool {
        idx.protein(day) >= profile.proteinTarget
    }

    private func perfectDay(_ day: Date, _ idx: DayIndex) -> Bool {
        DayCheck.perfect(day, index: idx, profile: profile, customHabits: customHabits.map(\.name))
    }

    // MARK: - Correlaties
    //
    // Geen statistiek, gewoon twee gemiddeldes naast elkaar: dagen mét X versus dagen
    // zónder X. Dat is wat je wil weten ("slaap ik beter → train ik zwaarder?") en het
    // is uitlegbaar. ponytail: pas tonen vanaf 5 dagen per groep, anders is het ruis.

    private struct Correlation: Identifiable {
        let id = UUID()
        let text: String
        let delta: Double   // + = de "mét"-groep scoort hoger
    }

    /// Splitst de laatste 120 dagen op `split` en vergelijkt het gemiddelde van `value`.
    private func compare(_ label: String, unit: String, days: Int = 120,
                         split: (Date) -> Bool, splitLabel: (with: String, without: String),
                         value: (Date) -> Double?) -> Correlation? {
        var withV: [Double] = [], withoutV: [Double] = []
        for day in daysBack(days) {
            guard let v = value(day) else { continue }
            if split(day) { withV.append(v) } else { withoutV.append(v) }
        }
        guard withV.count >= 5, withoutV.count >= 5 else { return nil }
        let a = withV.reduce(0, +) / Double(withV.count)
        let b = withoutV.reduce(0, +) / Double(withoutV.count)
        guard b > 0 || a > 0 else { return nil }
        let pct = b > 0 ? (a - b) / b * 100 : 0
        guard abs(pct) >= 5 else { return nil } // te klein om iets te betekenen
        let fmt = { (d: Double) in unit == "%" ? "\(Int(d))" : d.kgText }
        return Correlation(
            text: "\(label): \(fmt(a))\(unit) na \(splitLabel.with), \(fmt(b))\(unit) na \(splitLabel.without)",
            delta: pct)
    }

    private func avgCheckIn(_ keyPath: KeyPath<DayHabits, Int>, on day: Date, _ idx: DayIndex) -> Double? {
        guard let v = idx.habits(day)?[keyPath: keyPath], v > 0 else { return nil }
        return Double(v)
    }

    private func correlations(_ idx: DayIndex) -> [Correlation] {
        var out: [Correlation?] = []
        // Slaap → volume, energie
        out.append(compare("Trainingsvolume", unit: " kg",
                           split: { (idx.habits($0)?.sleepHours ?? 0) >= 7.5 },
                           splitLabel: ("7,5+ uur slaap", "kortere nachten"),
                           value: { let v = idx.volume($0); return v > 0 ? v : nil }))
        out.append(compare("Energie", unit: "/5",
                           split: { (idx.habits($0)?.sleepHours ?? 0) >= 7.5 },
                           splitLabel: ("7,5+ uur slaap", "kortere nachten"),
                           value: { avgCheckIn(\.energy, on: $0, idx) }))
        // Training → stemming, stress
        out.append(compare("Stemming", unit: "/5",
                           split: { idx.trained($0) },
                           splitLabel: ("trainingsdagen", "rustdagen"),
                           value: { avgCheckIn(\.mood, on: $0, idx) }))
        out.append(compare("Stress", unit: "/5",
                           split: { idx.trained($0) },
                           splitLabel: ("trainingsdagen", "rustdagen"),
                           value: { avgCheckIn(\.stress, on: $0, idx) }))
        // Stappen → energie en slaap
        out.append(compare("Energie", unit: "/5",
                           split: { (HealthService.shared.steps(on: $0) ?? 0) >= 8000 },
                           splitLabel: ("8.000+ stappen", "rustigere dagen"),
                           value: { avgCheckIn(\.energy, on: $0, idx) }))
        out.append(compare("Stappen", unit: "",
                           split: { idx.trained($0) },
                           splitLabel: ("trainingsdagen", "rustdagen"),
                           value: { HealthService.shared.steps(on: $0).map(Double.init) }))
        // Spierpijn → volume van de dag ervoor is te complex; houd het bij eiwit
        if profile.tracksFood {
            out.append(compare("Trainingsvolume", unit: " kg",
                               split: { proteinDone($0, idx) },
                               splitLabel: ("eiwitdoel gehaald", "eiwitdoel gemist"),
                               value: { let v = idx.volume($0); return v > 0 ? v : nil }))
        }
        return out.compactMap { $0 }.sorted { abs($0.delta) > abs($1.delta) }
    }

    // MARK: - Jaar-heatmap

    /// 53 weken × 7 dagen, oudste week links — GitHub-stijl, in één blik een jaar terug.
    private var yearWeeks: [[Date]] {
        let today = cal.startOfDay(for: .now)
        // begin bij de maandag van 52 weken geleden, zodat elke kolom een hele week is
        guard let from = cal.date(byAdding: .day, value: -364, to: today) else { return [] }
        let weekdayOffset = (cal.component(.weekday, from: from) + 5) % 7 // 0 = maandag
        guard let start = cal.date(byAdding: .day, value: -weekdayOffset, to: from) else { return [] }
        var weeks: [[Date]] = []
        var cursor = start
        while cursor <= today {
            var week: [Date] = []
            for i in 0..<7 {
                if let d = cal.date(byAdding: .day, value: i, to: cursor) { week.append(d) }
            }
            weeks.append(week)
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    /// Kleurintensiteit van de jaar-heatmap: exact dezelfde score als op het dashboard,
    /// alleen als 0…1. Eerder telde hij factoren ongewogen én zag hij een geplande
    /// rustdag als gemist, waardoor dezelfde dag hier anders kleurde dan daar.
    private func fill(_ day: Date, _ idx: DayIndex) -> Double {
        Double(DayCheck.score(day, index: idx, profile: profile, customHabits: customHabits.map(\.name))) / 100
    }

    private func daysBack(_ n: Int) -> [Date] {
        (0..<n).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
    }

    private func perfectLast30(_ idx: DayIndex) -> Int { daysBack(30).filter { perfectDay($0, idx) }.count }

    private func streak(_ idx: DayIndex) -> Int {
        DayCheck.streak(index: idx, profile: profile, customHabits: customHabits.map(\.name))
    }

    /// Namen van de factoren, voor de rijen van het habits-raster. De waarden per dag
    /// komen uit dezelfde `DayCheck.factors` als de score.
    private func factorNames(_ idx: DayIndex) -> [String] {
        DayCheck.factors(.now, index: idx, profile: profile,
                         customHabits: customHabits.map(\.name)).map(\.name)
    }

    // MARK: - Week review

    private func inLastWeek(_ date: Date) -> Bool {
        date > cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
    }

    private func week(_ idx: DayIndex) -> WeekStats {
        WeekStats(index: idx, profile: profile, sets: sets, weights: weights,
                  customHabits: customHabits.map(\.name))
    }

    private func advices(_ idx: DayIndex, plateaus: [(name: String, sessions: Int, kg: Double)]) -> [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        let week = week(idx)
        let open = profile.trainingsPerWeek - week.trainingDays
        if open > 0 {
            out.append(("Nog \(open) \(open == 1 ? "training" : "trainingen") deze week — je hebt er nog \(week.daysLeftInWeek) \(week.daysLeftInWeek == 1 ? "dag" : "dagen") voor.",
                        week.daysLeftInWeek <= open))
        }
        if week.proteinDays < 5 {
            out.append(("Eiwit is de bottleneck: zet elke ochtend een shake klaar.", true))
        }
        if let d = week.trend, profile.weeklyRate > 0, d < 0.05 {
            out.append(("Gewicht staat stil. Voeg ±250 kcal per dag toe.", true))
        }
        for lift in plateaus.prefix(2) {
            out.append(("\(lift.name) staat al \(lift.sessions) sessies vast — probeer een deload (-10%) of een variatie.", true))
        }
        let recentProteins = proteins.filter { inLastWeek($0.date) }
        let totalGrams = recentProteins.map(\.grams).reduce(0, +)
        if totalGrams > 100 {
            let evening = recentProteins.filter { cal.component(.hour, from: $0.date) >= 17 }.map(\.grams).reduce(0, +)
            let share = Double(evening) / Double(totalGrams)
            if share > 0.6 {
                out.append(("\(Int(share * 100))% van je eiwit komt na 17:00 — schuif ~30 g naar je ontbijt voor betere spreiding.", false))
            }
        }
        if out.isEmpty {
            out.append(("Alles staat goed. Gewoon doorgaan. 💪", false))
        }
        return out
    }

    // MARK: - Training analytics

    /// Alle oefening-gebonden statistiek, één keer per render berekend. Elke lift kwam
    /// hiervoor drie keer langs met een volledige scan over `sets` (tops, e1RM's, topgewicht).
    struct LiftStats {
        /// Topgewicht per sessie, oplopend op dag.
        var tops: [String: [(day: Date, kg: Double)]] = [:]
        /// Beste geschat 1RM per sessie, oplopend op dag.
        var e1rms: [String: [Double]] = [:]
        var topWeight: [String: Double] = [:]
        /// Meest gelogde oefeningen eerst.
        var mostLogged: [String] = []
    }

    private func makeLiftStats() -> LiftStats {
        var out = LiftStats()
        let byExercise = Dictionary(grouping: sets, by: \.exercise)
        for (name, group) in byExercise {
            let byDay = Dictionary(grouping: group) { dayKey($0.date) }.sorted { $0.key < $1.key }
            out.tops[name] = byDay.map { _, day in
                (day: day.map(\.date).min() ?? .now, kg: day.map(\.weightKg).max() ?? 0)
            }
            out.e1rms[name] = byDay.map { _, day in day.map { epley($0.weightKg, $0.reps) }.max() ?? 0 }
            out.topWeight[name] = group.map(\.weightKg).max() ?? 0
        }
        out.mostLogged = byExercise.mapValues(\.count).sorted { $0.value > $1.value }.prefix(4).map(\.key)
        return out
    }

    private var weeklyVolume: [(week: Date, volume: Double)] {
        let groups = Dictionary(grouping: sets) {
            cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? cal.startOfDay(for: $0.date)
        }
        var result: [(week: Date, volume: Double)] = []
        for (week, weekSets) in groups {
            var volume = 0.0
            for s in weekSets { volume += s.weightKg * Double(s.reps) }
            result.append((week: week, volume: volume))
        }
        result.sort { $0.week < $1.week }
        return result.suffix(volumeWeeks).map { $0 }
    }

    private func delta(_ tops: [(day: Date, kg: Double)]) -> Int? {
        guard tops.count >= 2, let first = tops.first?.kg, let last = tops.last?.kg, first > 0 else { return nil }
        return Int(((last - first) / first * 100).rounded())
    }

    // MARK: - Plateaus (geschat 1RM per sessie)

    /// Lifts zonder nieuw 1RM-record in de laatste 3 sessies (min. 5 sessies).
    private func plateauedLifts(_ stats: LiftStats) -> [(name: String, sessions: Int, kg: Double)] {
        var out: [(name: String, sessions: Int, kg: Double)] = []
        for (name, e) in stats.e1rms where isPlateaued(e) {
            out.append((name, e.count, stats.topWeight[name] ?? 0))
        }
        return out.sorted { $0.sessions > $1.sessions }
    }

    // MARK: - Volume per spiergroep (laatste 28 dagen)

    private func muscleIntensity(_ mv: [(muscle: String, volume: Double)]) -> [String: Double] {
        guard let maxV = mv.map(\.volume).max(), maxV > 0 else { return [:] }
        return Dictionary(mv.map { ($0.muscle, $0.volume / maxV) }, uniquingKeysWith: { a, _ in a })
    }

    private var muscleVolume: [(muscle: String, volume: Double)] {
        let muscleOf = Dictionary(exercises.map { ($0.name, $0.muscle) }, uniquingKeysWith: { a, _ in a })
        let since = cal.startOfDay(for: .now).addingTimeInterval(-27 * 86_400)
        var totals: [String: Double] = [:]
        for s in sets where s.date >= since {
            let m = muscleOf[s.exercise] ?? "Overig"
            totals[m, default: 0] += s.weightKg * Double(s.reps)
        }
        return totals.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    // MARK: - Body

    struct DayBox: Identifiable, Hashable {
        let day: Date
        var id: Date { day }
    }

    @State private var showReview = false
    @State private var volumeWeeks = 8
    @State private var selectedDayBox: DayBox?
    @State private var selectedMuscle: String?

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    private var content: some View {
        // Alles wat over de volledige tabellen loopt: precies één keer per render.
        // Elk blok hieronder krijgt het resultaat door i.p.v. het zelf te herberekenen.
        let idx = makeIndex()
        let stats = makeLiftStats()
        let factorNames = factorNames(idx)
        let plateaus = plateauedLifts(stats)
        let correlations = correlations(idx)
        return ScrollView {
            LazyVStack(spacing: 14) {
                BuiltScreenTitle("Inzicht", "Week \(profile.daysIn / 7 + 1)")
                // Volgorde = wat je ermee moet. Eerst hoe het gaat en wat je nu kunt doen,
                // dan je kracht, dan patronen, en het archief onderaan. De coach stond
                // eerder onder de bodymap — een scherm hoog scrollen voor het enige blok
                // dat je iets vraagt.
                weekBlock(idx)
                coachBlock(idx, plateaus: plateaus)
                perfectDaysBlock(idx)
                bodyMapBlock
                volumeBlock
                plateauBlock(plateaus)
                strengthBlock(stats)
                habitsBlock(idx, factorNames)
                correlationsBlock(correlations)
                yearBlock(idx)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        // De navigatiebalk blijft staan: dit was een tabwortel, en is nu een scherm dat je
        // vanaf Vandaag opent. Zonder balk is er geen terugknop.
        .sheet(isPresented: $showReview) { WeeklyReviewSheet(profile: profile) }
        .navigationDestination(item: $selectedDayBox) { box in
            DayDetailView(day: box.day, profile: profile)
        }
    }

    // MARK: - Blokken
    //
    // Los gehouden omdat de type-checker afhaakt op één grote VStack, en omdat een
    // scherm van tien secties anders niet te lezen is.

    private func weekBlock(_ idx: DayIndex) -> some View {
        VStack(spacing: 12) {
            WeekStatsGrid(week: week(idx), target: profile.trainingsPerWeek)
            Button {
                showReview = true
            } label: {
                Label("Bekijk week review", systemImage: "chart.bar.doc.horizontal")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.builtTint(.green), in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .builtCard()
    }

    @ViewBuilder private var bodyMapBlock: some View {
        let mv = muscleVolume
        let intensity = muscleIntensity(mv)
        BuiltSectionHeader("Volume per spiergroep")
        VStack(spacing: 10) {
            BodyMapView(values: intensity) { muscle in
                withAnimation(.snappy) { selectedMuscle = muscle }
            }
            if let m = selectedMuscle {
                HStack {
                    Circle().fill(Color.muscleTint(intensity[m] ?? 0)).frame(width: 10, height: 10)
                    Text(m).font(.subheadline.bold())
                    Spacer()
                    Text("\(Int(mv.first { $0.muscle == m }?.volume ?? 0)) kg")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .builtCard()
        BuiltFootnote("Laatste 28 dagen — voller groen = meer volume. Tik op een spiergroep. Zie je er een achterblijven, voeg er een oefening voor toe.")

        NavigationLink {
            RecordsView()
        } label: {
            HStack(spacing: 12) {
                BuiltIconTile(systemName: "trophy.fill", color: .orange)
                Text("Records").font(.headline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .builtCard()
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    @ViewBuilder private func coachBlock(_ idx: DayIndex, plateaus: [(name: String, sessions: Int, kg: Double)]) -> some View {
        let advices = advices(idx, plateaus: plateaus)
        if !advices.isEmpty {
            BuiltSectionHeader("Coach")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(advices, id: \.text) { advice in
                    Label {
                        Text(advice.text).font(.subheadline)
                    } icon: {
                        Image(systemName: advice.warning ? "exclamationmark.circle.fill" : "lightbulb")
                            .foregroundStyle(advice.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .builtCard()
        }
    }

    @ViewBuilder private func perfectDaysBlock(_ idx: DayIndex) -> some View {
        let streak = streak(idx)
        BuiltSectionHeader("Perfecte dagen")
        VStack(spacing: 12) {
            HStack {
                StatTile(value: "\(perfectLast30(idx))", label: "van 30 dagen", size: .large)
                Divider()
                StatTile(value: streak > 0 ? "🔥 \(streak)" : "—",
                         label: streak > 0 ? "huidige reeks" : "start vandaag je reeks", size: .large)
            }
            heatmap(idx)
        }
        .builtCard()
        BuiltFootnote("De laatste vijf weken — tik op een dag voor het logboek.")
    }

    @ViewBuilder private func yearBlock(_ idx: DayIndex) -> some View {
        BuiltSectionHeader("Je jaar")
        yearHeatmap(idx).builtCard()
        BuiltFootnote("Elke kolom is een week, elk blokje een dag — voller groen = meer habits gehaald. Tik op een dag voor het logboek.")
    }

    @ViewBuilder private func correlationsBlock(_ correlations: [Correlation]) -> some View {
        BuiltSectionHeader("Verbanden")
        VStack(alignment: .leading, spacing: 10) {
            if correlations.isEmpty {
                Text("Vul je dag-check-in een paar weken in — dan zie je hier wat écht verband houdt met je energie, stemming en training.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(correlations) { c in
                Label {
                    Text(c.text).font(.subheadline)
                } icon: {
                    Image(systemName: c.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(c.delta >= 0 ? .green : .orange)
                }
            }
        }
        .builtCard()
        if !correlations.isEmpty {
            BuiltFootnote("Gemiddeldes over de laatste 120 dagen, alleen getoond bij 5+ dagen per groep en 5%+ verschil. Verband is geen oorzaak.")
        }
    }

    @ViewBuilder private func habitsBlock(_ idx: DayIndex, _ names: [String]) -> some View {
        BuiltSectionHeader("Habits per dag")
        weekGrid(idx, names).builtCard()
    }

    @ViewBuilder private var volumeBlock: some View {
        BuiltSectionHeader("Trainingsvolume per week")
        VStack(spacing: 12) {
            Picker("Periode", selection: $volumeWeeks) {
                Text("8 wk").tag(8)
                Text("16 wk").tag(16)
                Text("26 wk").tag(26)
            }
            .pickerStyle(.segmented)
            if weeklyVolume.isEmpty {
                Text("Na je eerste trainingen zie hier je volume per week groeien.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                volumeChart
            }
        }
        .builtCard()
    }

    @ViewBuilder private func plateauBlock(_ plateaus: [(name: String, sessions: Int, kg: Double)]) -> some View {
        if !plateaus.isEmpty {
            BuiltSectionHeader("Plateaus")
            VStack(spacing: 0) {
                ForEach(Array(plateaus.enumerated()), id: \.element.name) { i, lift in
                    if i > 0 { Divider() }
                    NavigationLink {
                        ExerciseDetailView(exercise: lift.name)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.line.flattrend.xyaxis").foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lift.name).foregroundStyle(.primary)
                                Text("\(lift.sessions) sessies zonder nieuw record")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .builtCard()
            BuiltFootnote("Deload-tip: doe één week op ~90% met dezelfde reps, bouw daarna weer op. Vaak breek je er zo doorheen.")
        }
    }

    @ViewBuilder private func strengthBlock(_ stats: LiftStats) -> some View {
        BuiltSectionHeader("Kracht")
        if stats.mostLogged.isEmpty {
            Text("Na 2+ sessies per oefening verschijnt hier je krachtcurve.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .builtCard()
        }
        ForEach(stats.mostLogged, id: \.self) { name in
            NavigationLink {
                ExerciseDetailView(exercise: name)
            } label: {
                strengthRow(name, stats.tops[name] ?? []).builtCard()
            }
            .buttonStyle(PressableStyle(scale: 0.985))
        }
        if !stats.mostLogged.isEmpty {
            BuiltFootnote("Topgewicht per sessie; records op geschat 1RM (Epley).")
        }
    }

    /// 5 weken × 7 dagen; gevuld = perfecte dag, tik = logboek.
    private func heatmap(_ idx: DayIndex) -> some View {
        let days = (0..<35).compactMap { cal.date(byAdding: .day, value: -34 + $0, to: cal.startOfDay(for: .now)) }
        return VStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { col in
                        let day = days[row * 7 + col]
                        HeatCell(fill: perfectDay(day, idx) ? .green : Color(.quaternarySystemFill),
                                 isToday: cal.isDateInToday(day), height: 26) {
                            selectedDayBox = DayBox(day: day)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Een jaar in één blik. Horizontaal scrollbaar, nieuwste week rechts.
    private func yearHeatmap(_ idx: DayIndex) -> some View {
        let today = cal.startOfDay(for: .now)
        // Weken én vullingen één keer berekenen. `fill` stond hier drie keer per dag
        // (kleur, vinkje, accessibility) en `yearWeeks` werd ook nog eens los opgevraagd.
        let weeks = yearWeeks
        let todayKey = dayKey(today)
        let fills = Dictionary(uniqueKeysWithValues: weeks.flatMap { $0 }
            .filter { $0 <= today }
            .map { (dayKey($0), fill($0, idx)) })
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: 3) {
                            ForEach(week, id: \.self) { day in
                                if day > today {
                                    Color.clear.frame(width: 13, height: 13)
                                } else {
                                    let key = dayKey(day)
                                    let v = fills[key] ?? 0
                                    // `complete`: vorm naast kleur, want bij kleurenblindheid
                                    // is "alles gehaald" anders niet te onderscheiden.
                                    HeatCell(fill: Color.muscleTint(v), isToday: key == todayKey,
                                             size: 13, complete: v >= 0.999) {
                                        selectedDayBox = DayBox(day: day)
                                    }
                                    .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue("\(Int(v * 100))% van je habits")
                                }
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
        }
    }

    private var volumeChart: some View {
        let avg = weeklyVolume.map(\.volume).reduce(0, +) / Double(max(weeklyVolume.count, 1))
        return Chart {
            ForEach(weeklyVolume, id: \.week) { item in
                BarMark(
                    x: .value("Week", item.week, unit: .weekOfYear),
                    y: .value("Volume", item.volume)
                )
                .foregroundStyle(.green.gradient)
                .cornerRadius(4)
            }
            RuleMark(y: .value("Gemiddeld", avg))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("gem. \(Int(avg)) kg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(height: 170)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.3), value: volumeWeeks)
    }

    private func weekGrid(_ idx: DayIndex, _ names: [String]) -> some View {
        let days = daysBack(7).reversed().map { $0 }
        // Per dag dezelfde factorlijst als de score; op naam gematcht zodat de rijen kloppen.
        let doneByDay = Dictionary(uniqueKeysWithValues: days.map { day in
            (dayKey(day), Set(DayCheck.factors(day, index: idx, profile: profile,
                                               customHabits: customHabits.map(\.name))
                .filter(\.done).map(\.name)))
        })
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(days, id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(cal.isDateInToday(d) ? .primary : .secondary)
                }
            }
            ForEach(names, id: \.self) { name in
                GridRow {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(days, id: \.self) { d in
                        HeatCell(fill: doneByDay[dayKey(d)]?.contains(name) == true ? .green : Color(.quaternarySystemFill),
                                 isToday: cal.isDateInToday(d), size: 22) {
                            selectedDayBox = DayBox(day: d)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    fileprivate func strengthRow(_ name: String, _ tops: [(day: Date, kg: Double)]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                if let d = delta(tops) {
                    Text("\(d >= 0 ? "+" : "")\(d)% · \(tops.count) sessies")
                        .font(.caption)
                        .foregroundStyle(d >= 0 ? .green : .red)
                } else {
                    Text("\(tops.count) sessie\(tops.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tops.count >= 2 {
                Text("\(tops.last?.kg.kgText ?? "—") kg")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
                Chart(tops, id: \.day) { item in
                    LineMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                        .foregroundStyle(.green)
                    PointMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                        .foregroundStyle(.green)
                        .symbolSize(20)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 110, height: 40)
            } else {
                Text("\(tops.first?.kg.kgText ?? "—") kg")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// De vier weekgetallen. Inzicht en de zondagreview toonden ze allebei — met dezelfde
/// `WeekStats`, maar in twee lay-outs die uit elkaar konden lopen.
struct WeekStatsGrid: View {
    let week: WeekStats
    let target: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                StatTile(value: "\(week.trainingDays)/\(target)", label: "trainingen", size: .large,
                         tint: week.trainingDays > target ? .green : nil)
                Divider()
                StatTile(value: "\(week.proteinDays)/7", label: "eiwit-dagen", size: .large)
            }
            Divider()
            HStack {
                StatTile(value: week.trendText, label: "trend/week", size: .large)
                Divider()
                StatTile(value: "\(week.perfectDays)/7", label: "perfecte dagen", size: .large)
            }
        }
    }
}

// Zondag-ritueel (PRD Feature 6): de week als moment, niet als lijst.
struct WeeklyReviewSheet: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @State private var bounced = false

    private var cal: Calendar { .current }

    private var weekSets: [SetEntry] {
        sets.filter { $0.date > cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400) }
    }

    private var bestLift: (name: String, e1rm: Double)? {
        weekSets.map { ($0.exercise, epley($0.weightKg, $0.reps)) }
            .max { $0.1 < $1.1 }
            .map { (name: $0.0, e1rm: $0.1) }
    }

    private func verdict(_ week: WeekStats) -> String {
        let trainingOK = week.trainingDays >= profile.trainingsPerWeek
        if trainingOK && week.proteinDays >= 5 { return "Op schema — sterke week! 🚀" }
        if !trainingOK { return "Volgende week: \(profile.trainingsPerWeek) trainingen — verdeel ze zoals het uitkomt." }
        return "Volgende week: eiwit is de bottleneck — zet je shake klaar."
    }

    var body: some View {
        let idx = DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits)
        let week = WeekStats(index: idx, profile: profile, sets: sets, weights: weights,
                             customHabits: customHabits.map(\.name))
        return VStack(spacing: 20) {
            Text("📊")
                .font(.system(size: 52))
                .symbolEffect(.bounce, value: bounced)
            Text("Week \(profile.daysIn / 7 + 1) Review")
                .font(.title2.bold())
            WeekStatsGrid(week: week, target: profile.trainingsPerWeek)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
            if let bestLift {
                Text("🏆 Beste lift: \(bestLift.name) — e1RM \(bestLift.e1rm.kgText) kg")
                    .font(.subheadline.bold())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.builtTint(.yellow), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
            }
            Text(verdict(week))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Op naar volgende week 💪")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .onAppear { bounced = true }
    }

}

struct ExerciseDetailView: View {
    let exercise: String
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allExercises: [Exercise]
    @AppStorage("exerciseChartMetric") private var metric = ChartMetric.topWeight
    @AppStorage("exerciseChartRange") private var range = ChartRange.year
    /// De sessie waar de grafiek op staat. `nil` = de laatste; dat is waar je begint te
    /// kijken, en waar je na een periodewissel weer op uitkomt.
    @State private var pickedDay: Date?

    /// Wat de grafiek uitzet. Topgewicht zegt iets anders dan 1RM: zware triples laten je
    /// topgewicht stijgen terwijl je 1RM vlak blijft, en andersom.
    enum ChartMetric: String, CaseIterable, Identifiable {
        case topWeight, e1rm, setVolume
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topWeight: "Topgewicht"
            case .e1rm: "Geschat 1RM"
            case .setVolume: "Beste set"
            }
        }
        var unit: String { self == .setVolume ? "kg volume" : "kg" }
        func value(_ s: SetEntry) -> Double {
            switch self {
            case .topWeight: s.weightKg
            case .e1rm: epley(s.weightKg, s.reps)
            case .setVolume: s.weightKg * Double(s.reps)
            }
        }
    }

    enum ChartRange: String, CaseIterable, Identifiable {
        case quarter, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quarter: "3 mnd"
            case .year: "Jaar"
            case .all: "Alles"
            }
        }
        var days: Int? {
            switch self {
            case .quarter: 90
            case .year: 365
            case .all: nil
            }
        }
    }

    private var cal: Calendar { .current }
    private var sets: [SetEntry] { allSets.filter { $0.exercise == exercise } }

    private var days: [Date] {
        Set(sets.map { cal.startOfDay(for: $0.date) }).sorted(by: >)
    }

    /// De gekozen metriek per sessie, binnen de gekozen periode.
    private var chartPoints: [(day: Date, value: Double)] {
        points(metric: metric, days: range.days)
    }

    /// Beste waarde per sessiedag, oplopend. `days` = nil is de hele historie.
    private func points(metric: ChartMetric, days: Int?) -> [(day: Date, value: Double)] {
        let cutoff = days.flatMap { cal.date(byAdding: .day, value: -$0, to: .now) }
        let inRange = cutoff.map { c in sets.filter { $0.date >= c } } ?? sets
        return Dictionary(grouping: inRange) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.map(metric.value).max() ?? 0) }
            .sorted { $0.0 < $1.0 }
    }

    /// De as om de data heen, met een marge van een vijfde. `.automatic(includesZero: false)`
    /// liet een derde van het vlak leeg: bij 32–68 kg begon de as op 20 en liep 'ie tot 80.
    private var chartDomain: ClosedRange<Double> {
        let vals = chartPoints.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.18, 2)
        return (lo - pad)...(hi + pad)
    }

    /// De sessies waarin een record viel — het 🏅 in de grafiek.
    private var prDays: Set<Date> {
        let badges = prBadges
        return Set(sets.filter { badges[$0.syncID] != nil }.map { cal.startOfDay(for: $0.date) })
    }

    /// De sessie die de grafiek uitlicht, en die eronder uitgeschreven staat.
    private var focusDay: Date? {
        let points = chartPoints
        guard let last = points.last?.day else { return nil }
        guard let picked = pickedDay else { return last }
        // Na een periodewissel kan de gekozen dag buiten beeld vallen.
        return points.contains { $0.day == picked } ? picked : last
    }

    /// De sessie het dichtst bij waar je tikt. Charts geeft een willekeurige datum terug,
    /// geen punt — dus snappen we zelf.
    private func nearestDay(to date: Date) -> Date? {
        chartPoints.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }?.day
    }

    /// Beste gewicht per aantal reps, met wat je 1RM-schatting daar zegt.
    ///
    /// Alleen het gemeten record was misleidend: deed je 8 reps één keer op een lichte dag,
    /// dan stond er 32 kg onder een 7-reps-record van 68. Als richtpunt vlak voor je gaat
    /// tillen is dat waardeloos — de rij hoort af te lopen. De schatting (Epley omgekeerd,
    /// op je beste 1RM) loopt dat wel, en staat erbij zodra hij noemenswaardig hoger ligt
    /// dan wat je daar ooit deed.
    private func potential(_ reps: Int) -> Double? {
        guard let best = sets.map({ epley($0.weightKg, $0.reps) }).max(), best > 0 else { return nil }
        return best / (1 + Double(reps) / 30)
    }

    private var repMaxes: [(reps: Int, kg: Double, potential: Double?)] {
        Dictionary(grouping: sets.filter { (1...12).contains($0.reps) }, by: \.reps)
            .compactMap { reps, group -> (reps: Int, kg: Double, potential: Double?)? in
                guard let best = group.map(\.weightKg).max(), best > 0 else { return nil }
                // 2,5 kg is de kleinste sprong die je op een stang maakt; daaronder is het
                // ruis en zou de tweede regel alleen maar afleiden.
                let p = potential(reps).flatMap { $0 >= best + 2.5 ? $0 : nil }
                return (reps, best, p)
            }
            .sorted { $0.reps < $1.reps }
    }

    /// Welke records elke set brak op het moment dat hij gezet werd. Eén chronologische
    /// pass; per set opzoeken zou kwadratisch worden over de volledige historie.
    private var prBadges: [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        var bestWeight = 0.0, bestE1rm = 0.0, bestVolume = 0.0
        for s in sets.sorted(by: { $0.date < $1.date }) {
            let volume = s.weightKg * Double(s.reps)
            var badges: [String] = []
            // Alleen records tégen een bestaande historie: anders krijgt de allereerste
            // set van een oefening alle drie de badges en zegt het niets.
            if bestWeight > 0, s.weightKg > bestWeight + 0.01 { badges.append("Gewicht") }
            if bestE1rm > 0, epley(s.weightKg, s.reps) > bestE1rm + 0.01 { badges.append("1RM") }
            if bestVolume > 0, volume > bestVolume + 0.01 { badges.append("Volume") }
            if !badges.isEmpty { out[s.syncID] = badges }
            bestWeight = max(bestWeight, s.weightKg)
            bestE1rm = max(bestE1rm, epley(s.weightKg, s.reps))
            bestVolume = max(bestVolume, volume)
        }
        return out
    }

    /// Geschat 1RM (beste) per sessie, over de hele historie.
    private var e1rmSessions: [(day: Date, value: Double)] {
        points(metric: .e1rm, days: nil)
    }

    /// Lineaire trend op e1RM → kg/dag en de geprojecteerde waarde over 4 weken.
    private var projection: (slopePerWeek: Double, in4Weeks: Double, current: Double)? {
        let pts = e1rmSessions
        guard pts.count >= 3, let first = pts.first?.day else { return nil }
        let xs = pts.map { $0.day.timeIntervalSince(first) / 86_400 } // dagen
        let ys = pts.map(\.value)
        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxy = zip(xs, ys).map(*).reduce(0, +)
        let sxx = xs.map { $0 * $0 }.reduce(0, +)
        let denom = n * sxx - sx * sx
        guard abs(denom) > 0.0001 else { return nil }
        let slope = (n * sxy - sx * sy) / denom          // kg per dag
        let intercept = (sy - slope * sx) / n
        let lastX = xs.last ?? 0
        let current = slope * lastX + intercept
        let in4 = slope * (lastX + 28) + intercept
        return (slope * 7, in4, current)
    }

    /// Twee getallen naast elkaar in plaats van vier gelijkwaardige regels. Geschat 1RM is
    /// vergelijkbaar over rep-ranges heen, topgewicht is wat je in de sportschool voelt —
    /// geen van beide is een voetnoot van de ander. Sessies en sets zakken naar de voet.
    private var headline: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                bigStat("Geschat 1RM", sets.map { epley($0.weightKg, $0.reps) }.max())
                Divider().frame(height: 44)
                bigStat("Topgewicht", sets.map(\.weightKg).max())
            }
            Text("\(days.count) sessie\(days.count == 1 ? "" : "s") · \(sets.count) sets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func bigStat(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0.kgText) kg" } ?? "—")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                // Groen betekent één ding in deze app: een waarde. Een streepje is er geen.
                .foregroundStyle(value == nil ? Color.secondary : .green)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { "\($0.kgText) kilo" } ?? "geen")
    }

    /// De grafiek van "Verloop".
    ///
    /// Rechte lijnen tussen de sessies: `catmullRom` verzon een versnelling die er tussen
    /// twee trainingen niet was, en schoot bij een sprong van 32 naar 50 kg door boven de
    /// hoogste meting uit. Een 🏅 staat op de sessies waar een record viel, en de sessie
    /// waar je op tikt licht op met z'n waarde eronder.
    private func progressChart(_ points: [(day: Date, value: Double)]) -> some View {
        let domain = chartDomain
        let prs = prDays
        let focus = focusDay
        return Chart {
            ForEach(points, id: \.day) { item in
                AreaMark(x: .value("Dag", item.day),
                         yStart: .value("Onder", domain.lowerBound),
                         yEnd: .value(metric.unit, item.value))
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.22), .green.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Dag", item.day), y: .value(metric.unit, item.value))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(points, id: \.day) { item in
                PointMark(x: .value("Dag", item.day), y: .value(metric.unit, item.value))
                    .foregroundStyle(.green)
                    .symbolSize(item.day == focus ? 110 : 45)
                    .annotation(position: .top, spacing: 2) {
                        if prs.contains(item.day) { Text("🏅").font(.caption2) }
                    }
                    .annotation(position: .bottomLeading, spacing: 4) {
                        if item.day == focus {
                            Text("\(item.value.kgText) kg")
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            // Drie labels, niet vier: de vierde stond tegen de rand en werd afgekapt ("24…").
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geo[plotFrame].origin
                                if let date: Date = proxy.value(atX: value.location.x - origin.x) {
                                    pickedDay = nearestDay(to: date)
                                }
                            }
                    )
            }
        }
        .frame(height: 200)
        .padding(.vertical, 8)
    }

    /// De uitgelichte sessie, uitgeschreven onder de grafiek. Een punt in een lijn zegt
    /// "60 kg"; dit zegt met welke sets je daar kwam.
    private func focusRow(_ day: Date) -> some View {
        let daySets = sets.filter { dayKey($0.date) == dayKey(day) }
        let badges = prBadges
        return VStack(alignment: .leading, spacing: 8) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                .font(.subheadline.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(daySets, id: \.syncID) { set in
                        let pr = badges[set.syncID] != nil
                        Text("\(set.weightKg.kgText)×\(set.reps)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(pr ? Color.green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(pr ? Color.builtTint(.green) : Color(.tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        List {
            Section {
                headline
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Geschat 1RM via de Epley-formule: gewicht × (1 + reps ÷ 30).")
            }

            if let record = allExercises.first(where: { $0.name == exercise }) {
                Section("Spieren") {
                    LabeledContent("Primair", value: record.muscle)
                    if !record.secondaryMuscles.isEmpty {
                        LabeledContent("Meewerkend", value: record.secondaryMuscles.joined(separator: ", "))
                    }
                }
            }
            if days.count >= 2 {
                Section {
                    Picker("Metriek", selection: $metric) {
                        ForEach(ChartMetric.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    let points = chartPoints
                    if points.count >= 2 {
                        progressChart(points)
                        if let day = focusDay { focusRow(day) }
                    } else {
                        Text("Te weinig sessies in deze periode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                    Picker("Periode", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Verloop")
                } footer: {
                    Text("🏅 is een sessie waarin een record viel. Tik op een punt voor de sets van die training.")
                }
            } else if !sets.isEmpty {
                // Eén sessie: een lijn door één punt zegt niets, de sets binnen die sessie
                // wel. Vanaf de tweede sessie neemt de trendgrafiek hierboven het over.
                Section {
                    Chart(Array(sets.enumerated()), id: \.offset) { index, set in
                        BarMark(x: .value("Set", index + 1), y: .value("kg", set.weightKg))
                            .annotation(position: .top) {
                                Text("×\(set.reps)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .foregroundStyle(.green)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: sets.count)) }
                    .frame(height: 200)
                    .padding(.vertical, 8)
                } header: {
                    Text("Deze sessie")
                } footer: {
                    Text("Vanaf je tweede sessie zie je hier je topgewicht per sessie.")
                }
            }
            let maxes = repMaxes
            if maxes.count >= 2 {
                Section {
                    ForEach(maxes, id: \.reps) { item in
                        LabeledContent {
                            Text("\(item.kg.kgText) kg")
                        } label: {
                            Text("\(item.reps) \(item.reps == 1 ? "rep" : "reps")")
                            if let p = item.potential {
                                Text("je 1RM zegt ≈ \(p.kgText) kg")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit()
                    }
                } header: {
                    Text("Beste per aantal reps")
                } footer: {
                    Text("Je zwaarste set voor elk aantal herhalingen. Staat er een schatting onder, dan ben je daar nog nooit zwaar gegaan — dát is je richtpunt.")
                }
            }

            if let p = projection, p.slopePerWeek > 0.05 {
                Section {
                    LabeledContent("Tempo", value: "+\(p.slopePerWeek.formatted(.number.precision(.fractionLength(1)))) kg/week (1RM)")
                    LabeledContent("Over 4 weken", value: "≈ \(p.in4Weeks.kgText) kg")
                    Chart {
                        ForEach(e1rmSessions, id: \.day) { item in
                            PointMark(x: .value("Dag", item.day), y: .value("1RM", item.value))
                                .foregroundStyle(.green.opacity(0.5))
                        }
                        if let last = e1rmSessions.last,
                           let end = cal.date(byAdding: .day, value: 28, to: last.day) {
                            LineMark(x: .value("Dag", last.day), y: .value("1RM", p.current), series: .value("s", "proj"))
                            LineMark(x: .value("Dag", end), y: .value("1RM", p.in4Weeks), series: .value("s", "proj"))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        }
                    }
                    .foregroundStyle(.green)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 160)
                    .padding(.vertical, 8)
                } header: {
                    Text("Krachtprojectie")
                } footer: {
                    Text("Lineaire trend op je geschatte 1RM. Een schatting, geen belofte — blijf progressief overladen.")
                }
            }

            Section("Historie") {
                let badges = prBadges
                ForEach(days, id: \.self) { day in
                    let daySets = sets.filter { dayKey($0.date) == dayKey(day) }
                    let vol = Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                                .font(.headline)
                            Spacer()
                            Text("\(vol) kg")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        // Per set, zodat je ziet wélke set het record brak in plaats van
                        // alleen dát er die dag een record viel.
                        ForEach(daySets, id: \.syncID) { set in
                            HStack(spacing: 6) {
                                Text("\(set.weightKg.kgText)×\(set.reps)")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                ForEach(badges[set.syncID] ?? [], id: \.self) { badge in
                                    Text("🏅 \(badge)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.builtTint(.green), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .tabBarClearance()
        .navigationTitle(exercise)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Bekijken is de hoofdzaak, bewerken de uitzondering — vandaar rechtsboven en
            // niet de hele rij. Alleen als de oefening ook echt in de catalogus staat.
            if let record = allExercises.first(where: { $0.name == exercise }) {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Bewerk") { ExerciseEditor(exercise: record) }
                }
            }
        }
    }
}
