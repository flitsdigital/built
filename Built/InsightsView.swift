import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    let profile: Profile
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query private var habitLogs: [HabitLog]
    @Query private var exercises: [Exercise]

    private var cal: Calendar { .current }

    // MARK: - Dag-checks

    private func proteinDone(_ day: Date) -> Bool {
        proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.grams).reduce(0, +) >= profile.proteinTarget
    }
    private func trained(_ day: Date) -> Bool { sets.contains { cal.isDate($0.date, inSameDayAs: day) } }
    private func weighed(_ day: Date) -> Bool { weights.contains { cal.isDate($0.date, inSameDayAs: day) } }
    private func habit(_ day: Date) -> DayHabits? { habits.first { cal.isDate($0.date, inSameDayAs: day) } }

    private func perfectDay(_ day: Date) -> Bool {
        DayCheck.perfect(day, proteins: proteins, weights: weights, habits: habits, target: profile.proteinTarget,
                         requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                         sets: sets, trainingDays: profile.trainingDays)
    }

    private func daysBack(_ n: Int) -> [Date] {
        (0..<n).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
    }

    private var perfectLast30: Int { daysBack(30).filter(perfectDay).count }

    private var streak: Int {
        DayCheck.streak(proteins: proteins, weights: weights, habits: habits, target: profile.proteinTarget,
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                        sets: sets, trainingDays: profile.trainingDays)
    }

    private var factors: [(name: String, done: (Date) -> Bool)] {
        var out: [(name: String, done: (Date) -> Bool)] =
            [("Eiwit", proteinDone),
             ("Training", trained),
             ("Gewicht", weighed)]
        if profile.tracksCreatine { out.append(("Creatine", { habit($0)?.creatine == true })) }
        if profile.tracksSleep { out.append(("Slaap", { habit($0)?.sleptEnough == true })) }
        for custom in customHabits {
            let name = custom.name
            out.append((name, { day in
                self.habitLogs.contains { $0.name == name && Calendar.current.isDate($0.date, inSameDayAs: day) }
            }))
        }
        return out
    }

    // MARK: - Week review

    private func inLastWeek(_ date: Date) -> Bool {
        date > cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
    }

    private var trainingDays: Int {
        Set(sets.filter { inLastWeek($0.date) }.map { cal.startOfDay(for: $0.date) }).count
    }

    private var proteinDays: Int {
        daysBack(7).filter(proteinDone).count
    }

    private var weekDelta: Double? { weights.trendPerWeek }

    private var onTrack: Bool {
        guard let d = weekDelta else { return true }
        return trainingDays >= profile.trainingsPerWeek && abs(d - profile.weeklyRate) < 0.2
    }

    private var advices: [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        if trainingDays < profile.trainingsPerWeek {
            out.append(("Plan je trainingen vooraf in — je mist er \(profile.trainingsPerWeek - trainingDays) deze week.", true))
        }
        if proteinDays < 5 {
            out.append(("Eiwit is de bottleneck: zet elke ochtend een shake klaar.", true))
        }
        if let d = weekDelta, profile.weeklyRate > 0, d < 0.05 {
            out.append(("Gewicht staat stil. Voeg ±250 kcal per dag toe.", true))
        }
        for lift in plateauedLifts.prefix(2) {
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

    private var topExercises: [String] {
        Dictionary(grouping: sets, by: \.exercise)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)
    }

    private func sessionTops(_ name: String) -> [(day: Date, kg: Double)] {
        Dictionary(grouping: sets.filter { $0.exercise == name }) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.map(\.weightKg).max() ?? 0) }
            .sorted { $0.0 < $1.0 }
    }

    private func delta(_ tops: [(day: Date, kg: Double)]) -> Int? {
        guard tops.count >= 2, let first = tops.first?.kg, let last = tops.last?.kg, first > 0 else { return nil }
        return Int(((last - first) / first * 100).rounded())
    }

    // MARK: - Plateaus (geschat 1RM per sessie)

    private func sessionE1RMs(_ name: String) -> [Double] {
        Dictionary(grouping: sets.filter { $0.exercise == name }) { cal.startOfDay(for: $0.date) }
            .sorted { $0.key < $1.key }
            .map { _, daySets in daySets.map { epley($0.weightKg, $0.reps) }.max() ?? 0 }
    }

    /// Lifts zonder nieuw 1RM-record in de laatste 3 sessies (min. 5 sessies).
    private var plateauedLifts: [(name: String, sessions: Int, kg: Double)] {
        var out: [(String, Int, Double)] = []
        for name in Set(sets.map(\.exercise)) {
            let e = sessionE1RMs(name)
            guard e.count >= 5 else { continue }
            let priorBest = e.dropLast(3).max() ?? 0
            let recentBest = e.suffix(3).max() ?? 0
            if recentBest <= priorBest * 1.005 {
                let topKg = sets.filter { $0.exercise == name }.map(\.weightKg).max() ?? 0
                out.append((name, e.count, topKg))
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    // MARK: - Volume per spiergroep (laatste 28 dagen)

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

    private var perfectLast7: Int { daysBack(7).filter(perfectDay).count }

    var body: some View {
        List {
            Section("Deze week") {
                HStack {
                    statTile(value: "\(trainingDays)/\(profile.trainingsPerWeek)", label: "trainingen")
                    Divider()
                    statTile(value: "\(proteinDays)/7", label: "eiwit-dagen")
                }
                HStack {
                    statTile(value: weekDelta.map { "\($0 >= 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(1))))" } ?? "—",
                             label: "kg deze week")
                    Divider()
                    statTile(value: "\(perfectLast7)/7", label: "perfecte dagen")
                }
                Button {
                    showReview = true
                } label: {
                    Label("Bekijk week review", systemImage: "chart.bar.doc.horizontal")
                }
            }

            Section("Coach") {
                ForEach(advices, id: \.text) { advice in
                    Label {
                        Text(advice.text)
                    } icon: {
                        Image(systemName: advice.warning ? "exclamationmark.circle.fill" : "lightbulb")
                            .foregroundStyle(advice.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    .font(.subheadline)
                }
            }

            Section {
                HStack {
                    statTile(value: "\(perfectLast30)", label: "van 30 dagen")
                    Divider()
                    statTile(value: streak > 0 ? "🔥 \(streak)" : "—",
                             label: streak > 0 ? "huidige reeks" : "start vandaag je reeks")
                }
                heatmap
            } header: {
                Text("Perfecte dagen")
            } footer: {
                Text("De laatste vijf weken — tik op een dag voor het logboek.")
            }

            Section("Habits per dag") {
                weekGrid
            }

            Section("Trainingsvolume per week") {
                Picker("Periode", selection: $volumeWeeks) {
                    Text("8 wk").tag(8)
                    Text("16 wk").tag(16)
                    Text("26 wk").tag(26)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                if weeklyVolume.isEmpty {
                    Text("Na je eerste trainingen zie hier je volume per week groeien.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    volumeChart
                }
            }

            if !muscleVolume.isEmpty {
                Section {
                    ForEach(muscleVolume, id: \.muscle) { row in
                        HStack {
                            Text(row.muscle)
                            Spacer()
                            Text("\(Int(row.volume)) kg")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .listRowSeparator(.hidden)
                        muscleBar(row.volume, max: muscleVolume.first?.volume ?? 1)
                    }
                } header: {
                    Text("Volume per spiergroep")
                } footer: {
                    Text("Laatste 28 dagen. Zie je een spiergroep achterblijven, voeg er een oefening voor toe.")
                }
            }

            if !plateauedLifts.isEmpty {
                Section {
                    ForEach(plateauedLifts, id: \.name) { lift in
                        NavigationLink {
                            ExerciseDetailView(exercise: lift.name)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lift.name)
                                    Text("\(lift.sessions) sessies zonder nieuw record")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "chart.line.flattrend.xyaxis")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Plateaus")
                } footer: {
                    Text("Deload-tip: doe één week op ~90% met dezelfde reps, bouw daarna weer op. Vaak breek je er zo doorheen.")
                }
            }

            Section {
                if topExercises.isEmpty {
                    Text("Na 2+ sessies per oefening verschijnt hier je krachtcurve.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(topExercises, id: \.self) { name in
                    NavigationLink {
                        ExerciseDetailView(exercise: name)
                    } label: {
                        strengthRow(name)
                    }
                }
            } header: {
                Text("Kracht")
            } footer: {
                if !topExercises.isEmpty {
                    Text("Topgewicht per sessie; records op geschat 1RM (Epley).")
                }
            }
        }
        .navigationTitle("Inzicht")
        .sheet(isPresented: $showReview) { WeeklyReviewSheet(profile: profile) }
        .navigationDestination(item: $selectedDayBox) { box in
            DayDetailView(day: box.day, profile: profile)
        }
    }

    private func muscleBar(_ value: Double, max: Double) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
                .fill(.green.opacity(0.25))
                .frame(width: geo.size.width * (max > 0 ? value / max : 0), height: 6)
        }
        .frame(height: 6)
        .listRowSeparator(.hidden)
    }

    /// 5 weken × 7 dagen; gevuld = perfecte dag, tik = logboek.
    private var heatmap: some View {
        let days = (0..<35).compactMap { cal.date(byAdding: .day, value: -34 + $0, to: cal.startOfDay(for: .now)) }
        return VStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { col in
                        let day = days[row * 7 + col]
                        Button {
                            selectedDayBox = DayBox(day: day)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(perfectDay(day) ? Color.green : Color(.quaternarySystemFill))
                                .frame(height: 26)
                                .overlay {
                                    if cal.isDateInToday(day) {
                                        RoundedRectangle(cornerRadius: 4)
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

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var weekGrid: some View {
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
                            RoundedRectangle(cornerRadius: 4)
                                .fill(factor.done(d) ? Color.green : Color(.quaternarySystemFill))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if cal.isDateInToday(d) {
                                        RoundedRectangle(cornerRadius: 4)
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

    fileprivate func strengthRow(_ name: String) -> some View {
        let tops = sessionTops(name)
        return HStack {
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
    private var trainingDays: Int { Set(weekSets.map { cal.startOfDay(for: $0.date) }).count }
    private var weekVolume: Int { Int(weekSets.map { $0.weightKg * Double($0.reps) }.reduce(0, +)) }

    private var proteinDays: Int {
        (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
            .filter { day in
                proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.grams).reduce(0, +) >= profile.proteinTarget
            }.count
    }

    private var perfectDays: Int {
        (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
            .filter {
                DayCheck.perfect($0, proteins: proteins, weights: weights, habits: habits,
                                 target: profile.proteinTarget,
                                 requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                                 sets: sets, trainingDays: profile.trainingDays)
            }.count
    }

    private var bestLift: (name: String, e1rm: Double)? {
        weekSets.map { ($0.exercise, epley($0.weightKg, $0.reps)) }
            .max { $0.1 < $1.1 }
            .map { (name: $0.0, e1rm: $0.1) }
    }

    private var weekDelta: Double? { weights.trendPerWeek }

    private var verdict: String {
        let trainingOK = trainingDays >= profile.trainingsPerWeek
        let proteinOK = proteinDays >= 5
        if trainingOK && proteinOK { return "Op schema — sterke week! 🚀" }
        if !trainingOK { return "Volgende week: plan je \(profile.trainingsPerWeek) trainingen vooraf in." }
        return "Volgende week: eiwit is de bottleneck — zet je shake klaar."
    }

    var body: some View {
        VStack(spacing: 20) {
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
                tile(weekDelta.map { "\($0 >= 0 ? "+" : "")\($0.formatted(.number.precision(.fractionLength(1))))" } ?? "—", "kg deze week")
                tile("\(perfectDays)/7", "perfecte dagen")
            }
            if let bestLift {
                Text("🏆 Beste lift: \(bestLift.name) — e1RM \(bestLift.e1rm.kgText) kg")
                    .font(.subheadline.bold())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(verdict)
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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

    private func isRecordDay(_ day: Date) -> Bool {
        let dayBest = sets.filter { cal.isDate($0.date, inSameDayAs: day) }.map { epley($0.weightKg, $0.reps) }.max() ?? 0
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
            Section("Historie") {
                ForEach(days, id: \.self) { day in
                    let daySets = sets.filter { cal.isDate($0.date, inSameDayAs: day) }
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
