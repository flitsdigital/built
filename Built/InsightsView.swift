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
        DayCheck.perfect(day, index: idx, target: profile.proteinTarget,
                         requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                         trainingDays: profile.trainingDays, requireFood: profile.tracksFood)
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

    /// Vervulling van een dag (0…1) voor de kleurintensiteit van de heatmap.
    /// Neemt `factors` als parameter: die lijst is per render constant, dus 'm hier
    /// opnieuw opbouwen zou 371× hetzelfde werk zijn.
    private func fill(_ day: Date, _ factors: [(name: String, done: (Date) -> Bool)]) -> Double {
        guard !factors.isEmpty else { return 0 }
        var done = 0.0
        for f in factors where f.done(day) { done += 1 }
        return done / Double(factors.count)
    }

    private func daysBack(_ n: Int) -> [Date] {
        (0..<n).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
    }

    private func perfectLast30(_ idx: DayIndex) -> Int { daysBack(30).filter { perfectDay($0, idx) }.count }

    private func streak(_ idx: DayIndex) -> Int {
        DayCheck.streak(index: idx, target: profile.proteinTarget,
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                        trainingDays: profile.trainingDays, requireFood: profile.tracksFood)
    }

    private func factors(_ idx: DayIndex) -> [(name: String, done: (Date) -> Bool)] {
        var out: [(name: String, done: (Date) -> Bool)] =
            [("Training", { idx.trained($0) }),
             ("Gewicht", { idx.weighed($0) })]
        if profile.tracksFood { out.insert(("Eiwit", { proteinDone($0, idx) }), at: 0) }
        if profile.tracksCreatine { out.append(("Creatine", { idx.habits($0)?.creatine == true })) }
        if profile.tracksSleep { out.append(("Slaap", { idx.habits($0)?.sleptEnough == true })) }
        for custom in customHabits {
            let name = custom.name
            out.append((name, { idx.logged(name, on: $0) }))
        }
        return out
    }

    // MARK: - Week review

    private func inLastWeek(_ date: Date) -> Bool {
        date > cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
    }

    private var trainingDays: Int {
        Set(sets.filter { inLastWeek($0.date) }.map { dayKey($0.date) }).count
    }

    private func proteinDays(_ idx: DayIndex) -> Int {
        daysBack(7).filter { proteinDone($0, idx) }.count
    }

    private var weekDelta: Double? { weights.trendPerWeek }

    private func advices(_ idx: DayIndex, plateaus: [(name: String, sessions: Int, kg: Double)]) -> [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        let trainingDays = trainingDays
        if trainingDays < profile.trainingsPerWeek {
            out.append(("Plan je trainingen vooraf in — je mist er \(profile.trainingsPerWeek - trainingDays) deze week.", true))
        }
        if proteinDays(idx) < 5 {
            out.append(("Eiwit is de bottleneck: zet elke ochtend een shake klaar.", true))
        }
        if let d = weekDelta, profile.weeklyRate > 0, d < 0.05 {
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
        for (name, e) in stats.e1rms where e.count >= 5 {
            let priorBest = e.dropLast(3).max() ?? 0
            let recentBest = e.suffix(3).max() ?? 0
            if recentBest <= priorBest * 1.005 {
                out.append((name, e.count, stats.topWeight[name] ?? 0))
            }
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

    private func perfectLast7(_ idx: DayIndex) -> Int { daysBack(7).filter { perfectDay($0, idx) }.count }

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    @ViewBuilder private var content: some View {
        // Alles wat over de volledige tabellen loopt: precies één keer per render.
        // Elk blok hieronder krijgt het resultaat door i.p.v. het zelf te herberekenen.
        let idx = makeIndex()
        let stats = makeLiftStats()
        let factors = factors(idx)
        let plateaus = plateauedLifts(stats)
        let correlations = correlations(idx)
        return ScrollView {
            LazyVStack(spacing: 14) {
                BuiltScreenTitle("Inzicht", "Week \(profile.daysIn / 7 + 1)")
                weekBlock(idx)
                bodyMapBlock
                coachBlock(idx, plateaus: plateaus)
                perfectDaysBlock(idx)
                yearBlock(factors)
                correlationsBlock(correlations)
                habitsBlock(factors)
                volumeBlock
                plateauBlock(plateaus)
                strengthBlock(stats)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
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
            HStack {
                StatTile(value: "\(trainingDays)/\(profile.trainingsPerWeek)", label: "trainingen", large: true)
                Divider()
                StatTile(value: "\(proteinDays(idx))/7", label: "eiwit-dagen", large: true)
            }
            Divider()
            HStack {
                StatTile(value: weekDelta.map { "\($0 >= 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(1))))" } ?? "—",
                         label: "trend/week", large: true)
                Divider()
                StatTile(value: "\(perfectLast7(idx))/7", label: "perfecte dagen", large: true)
            }
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
                StatTile(value: "\(perfectLast30(idx))", label: "van 30 dagen", large: true)
                Divider()
                StatTile(value: streak > 0 ? "🔥 \(streak)" : "—",
                         label: streak > 0 ? "huidige reeks" : "start vandaag je reeks", large: true)
            }
            heatmap(idx)
        }
        .builtCard()
        BuiltFootnote("De laatste vijf weken — tik op een dag voor het logboek.")
    }

    @ViewBuilder private func yearBlock(_ factors: [(name: String, done: (Date) -> Bool)]) -> some View {
        BuiltSectionHeader("Je jaar")
        yearHeatmap(factors).builtCard()
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

    @ViewBuilder private func habitsBlock(_ factors: [(name: String, done: (Date) -> Bool)]) -> some View {
        BuiltSectionHeader("Habits per dag")
        weekGrid(factors).builtCard()
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lift.name).foregroundStyle(.primary)
                                Text("\(lift.sessions) sessies zonder nieuw record")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
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
                        Button {
                            selectedDayBox = DayBox(day: day)
                        } label: {
                            RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                .fill(perfectDay(day, idx) ? Color.green : Color(.quaternarySystemFill))
                                .frame(height: 26)
                                .overlay {
                                    if cal.isDateInToday(day) {
                                        RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                            .strokeBorder(.green, lineWidth: 1.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Een jaar in één blik. Horizontaal scrollbaar, nieuwste week rechts.
    private func yearHeatmap(_ factors: [(name: String, done: (Date) -> Bool)]) -> some View {
        let today = cal.startOfDay(for: .now)
        // Weken én vullingen één keer berekenen. `fill` stond hier drie keer per dag
        // (kleur, vinkje, accessibility) en `yearWeeks` werd ook nog eens los opgevraagd.
        let weeks = yearWeeks
        let todayKey = dayKey(today)
        let fills = Dictionary(uniqueKeysWithValues: weeks.flatMap { $0 }
            .filter { $0 <= today }
            .map { (dayKey($0), fill($0, factors)) })
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
                                    Button {
                                        selectedDayBox = DayBox(day: day)
                                    } label: {
                                        RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                            .fill(Color.muscleTint(v))
                                            .frame(width: 13, height: 13)
                                            .overlay {
                                                // Vorm naast kleur: bij kleurenblindheid is
                                                // "alles gehaald" anders niet te onderscheiden.
                                                if v >= 0.999 {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 8, weight: .black))
                                                        .foregroundStyle(.white)
                                                }
                                                if key == todayKey {
                                                    RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                                        .strokeBorder(.green, lineWidth: 1.5)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
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

    private func weekGrid(_ factors: [(name: String, done: (Date) -> Bool)]) -> some View {
        let days = daysBack(7).reversed().map { $0 }
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(days, id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(cal.isDateInToday(d) ? .primary : .secondary)
                }
            }
            ForEach(factors, id: \.name) { factor in
                GridRow {
                    Text(factor.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(days, id: \.self) { d in
                        Button {
                            selectedDayBox = DayBox(day: d)
                        } label: {
                            RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                .fill(factor.done(d) ? Color.green : Color(.quaternarySystemFill))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if cal.isDateInToday(d) {
                                        RoundedRectangle(cornerRadius: BuiltRadius.micro)
                                            .strokeBorder(.green.opacity(0.7), lineWidth: 1.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
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

// Zondag-ritueel (PRD Feature 6): de week als moment, niet als lijst.
struct WeeklyReviewSheet: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]
    @State private var bounced = false

    private var cal: Calendar { .current }

    private func inLastWeek(_ date: Date) -> Bool {
        date > cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
    }

    private var weekSets: [SetEntry] { sets.filter { inLastWeek($0.date) } }
    private var trainingDays: Int { Set(weekSets.map { dayKey($0.date) }).count }
    private var weekVolume: Int { Int(weekSets.map { $0.weightKg * Double($0.reps) }.reduce(0, +)) }

    private var lastSevenDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
    }

    private func proteinDays(_ idx: DayIndex) -> Int {
        lastSevenDays.filter { idx.protein($0) >= profile.proteinTarget }.count
    }

    private func perfectDays(_ idx: DayIndex) -> Int {
        lastSevenDays.filter {
            DayCheck.perfect($0, index: idx, target: profile.proteinTarget,
                             requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                             trainingDays: profile.trainingDays)
        }.count
    }

    private var bestLift: (name: String, e1rm: Double)? {
        weekSets.map { ($0.exercise, epley($0.weightKg, $0.reps)) }
            .max { $0.1 < $1.1 }
            .map { (name: $0.0, e1rm: $0.1) }
    }

    private var weekDelta: Double? { weights.trendPerWeek }

    private func verdict(proteinDays: Int) -> String {
        let trainingOK = trainingDays >= profile.trainingsPerWeek
        if trainingOK && proteinDays >= 5 { return "Op schema — sterke week! 🚀" }
        if !trainingOK { return "Volgende week: plan je \(profile.trainingsPerWeek) trainingen vooraf in." }
        return "Volgende week: eiwit is de bottleneck — zet je shake klaar."
    }

    var body: some View {
        let idx = DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits)
        let proteinDays = proteinDays(idx)
        return VStack(spacing: 20) {
            Text("📊")
                .font(.system(size: 52))
                .symbolEffect(.bounce, value: bounced)
            Text("Week \(profile.daysIn / 7 + 1) Review")
                .font(.title2.bold())
            HStack {
                tile("\(trainingDays)/\(profile.trainingsPerWeek)", "trainingen")
                tile("\(proteinDays)/7", "eiwit-dagen")
            }
            HStack {
                tile(weekDelta.map { "\($0 >= 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(1))))" } ?? "—", "trend/week")
                tile("\(perfectDays(idx))/7", "perfecte dagen")
            }
            if let bestLift {
                Text("🏆 Beste lift: \(bestLift.name) — e1RM \(bestLift.e1rm.kgText) kg")
                    .font(.subheadline.bold())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.builtTint(.yellow), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
            }
            Text(verdict(proteinDays: proteinDays))
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

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
    }
}

struct ExerciseDetailView: View {
    let exercise: String
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]

    private var cal: Calendar { .current }
    private var sets: [SetEntry] { allSets.filter { $0.exercise == exercise } }

    private var days: [Date] {
        Set(sets.map { cal.startOfDay(for: $0.date) }).sorted(by: >)
    }

    private var tops: [(day: Date, kg: Double)] {
        Dictionary(grouping: sets) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.map(\.weightKg).max() ?? 0) }
            .sorted { $0.0 < $1.0 }
    }

    /// Geschat 1RM (beste) per sessie.
    private var e1rmSessions: [(day: Date, kg: Double)] {
        Dictionary(grouping: sets) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.map { epley($0.weightKg, $0.reps) }.max() ?? 0) }
            .sorted { $0.0 < $1.0 }
    }

    /// Lineaire trend op e1RM → kg/dag en de geprojecteerde waarde over 4 weken.
    private var projection: (slopePerWeek: Double, in4Weeks: Double, current: Double)? {
        let pts = e1rmSessions
        guard pts.count >= 3, let first = pts.first?.day else { return nil }
        let xs = pts.map { $0.day.timeIntervalSince(first) / 86_400 } // dagen
        let ys = pts.map(\.kg)
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

    private func isRecordDay(_ day: Date) -> Bool {
        let key = dayKey(day)
        let dayBest = sets.filter { dayKey($0.date) == key }.map { epley($0.weightKg, $0.reps) }.max() ?? 0
        let before = sets.filter { $0.date < cal.startOfDay(for: day) }.map { epley($0.weightKg, $0.reps) }.max() ?? 0
        return before > 0 && dayBest > before + 0.1
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Beste gewicht", value: "\(sets.map(\.weightKg).max()?.kgText ?? "—") kg 🏆")
                LabeledContent("Geschat 1RM", value: "\(sets.map { epley($0.weightKg, $0.reps) }.max()?.kgText ?? "—") kg")
                LabeledContent("Sessies", value: "\(days.count)")
                LabeledContent("Totaal sets", value: "\(sets.count)")
            } footer: {
                Text("Geschat 1RM via de Epley-formule: gewicht × (1 + reps ÷ 30).")
            }
            if tops.count >= 2 {
                Section("Topgewicht per sessie") {
                    Chart(tops, id: \.day) { item in
                        LineMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .foregroundStyle(.green)
                    .frame(height: 200)
                    .padding(.vertical, 8)
                }
            }
            if let p = projection, p.slopePerWeek > 0.05 {
                Section {
                    LabeledContent("Tempo", value: "+\(p.slopePerWeek.formatted(.number.precision(.fractionLength(1)))) kg/week (1RM)")
                    LabeledContent("Over 4 weken", value: "≈ \(p.in4Weeks.kgText) kg")
                    Chart {
                        ForEach(e1rmSessions, id: \.day) { item in
                            PointMark(x: .value("Dag", item.day), y: .value("1RM", item.kg))
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
                ForEach(days, id: \.self) { day in
                    let daySets = sets.filter { dayKey($0.date) == dayKey(day) }
                    let vol = Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                                .font(.headline)
                            if isRecordDay(day) {
                                Text("🏆").font(.caption)
                            }
                            Spacer()
                            Text("\(vol) kg")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(daySets.map { "\($0.weightKg.kgText)×\($0.reps)" }.joined(separator: "  "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tabBarClearance()
        .navigationTitle(exercise)
        .navigationBarTitleDisplayMode(.inline)
    }
}
