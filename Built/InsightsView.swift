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
                         requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
    }

    private func daysBack(_ n: Int) -> [Date] {
        (0..<n).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
    }

    private var perfectLast30: Int { daysBack(30).filter(perfectDay).count }

    private var streak: Int {
        DayCheck.streak(proteins: proteins, weights: weights, habits: habits, target: profile.proteinTarget,
                        requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep)
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

    private var advice: [String] {
        var out: [String] = []
        if trainingDays < profile.trainingsPerWeek {
            out.append("Plan je trainingen vooraf in — je mist er \(profile.trainingsPerWeek - trainingDays) deze week.")
        }
        if proteinDays < 5 {
            out.append("Eiwit is de bottleneck: zet elke ochtend een shake klaar.")
        }
        if let d = weekDelta, profile.weeklyRate > 0, d < 0.05 {
            out.append("Gewicht staat stil. Voeg ±250 kcal per dag toe.")
        }
        if out.isEmpty {
            out.append("Alles staat goed. Gewoon doorgaan. 💪")
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
        return result.suffix(8).map { $0 }
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

    // MARK: - Body

    var body: some View {
        List {
            Section("Week \(profile.daysIn / 7 + 1) Review") {
                LabeledContent("Training", value: "\(trainingDays)/\(profile.trainingsPerWeek) voltooid \(trainingDays >= profile.trainingsPerWeek ? "✅" : "")")
                LabeledContent("Eiwit", value: "\(proteinDays)/7 dagen gehaald")
                if let d = weekDelta {
                    LabeledContent("Gewicht", value: "\(d >= 0 ? "+" : "")\(d.formatted(.number.precision(.fractionLength(1)))) kg")
                }
                LabeledContent("Voorspelling", value: onTrack ? "Op schema 🚀" : "Bijsturen nodig")
            }

            Section("Perfecte dagen") {
                HStack {
                    statTile(value: "\(perfectLast30)", label: "van 30 dagen")
                    Divider()
                    statTile(value: "🔥 \(streak)", label: "huidige reeks")
                }
            }

            Section("Deze week") {
                weekGrid
            }

            if !weeklyVolume.isEmpty {
                Section("Trainingsvolume per week") {
                    Chart(weeklyVolume, id: \.week) { item in
                        BarMark(
                            x: .value("Week", item.week, unit: .weekOfYear),
                            y: .value("Volume", item.volume)
                        )
                        .foregroundStyle(.green.gradient)
                        .cornerRadius(4)
                    }
                    .frame(height: 160)
                    .padding(.vertical, 8)
                }
            }

            if !topExercises.isEmpty {
                Section("Kracht") {
                    ForEach(topExercises, id: \.self) { name in
                        NavigationLink {
                            ExerciseDetailView(exercise: name)
                        } label: {
                            strengthRow(name)
                        }
                    }
                }
            }

            Section("Coach") {
                ForEach(advice, id: \.self) { line in
                    Label(line, systemImage: "lightbulb")
                }
            }
        }
        .navigationTitle("Inzicht")
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
                        RoundedRectangle(cornerRadius: 4)
                            .fill(factor.done(d) ? Color.green : Color(.quaternarySystemFill))
                            .frame(width: 22, height: 22)
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

    var body: some View {
        List {
            Section {
                LabeledContent("Beste gewicht", value: "\(sets.map(\.weightKg).max()?.kgText ?? "—") kg 🏆")
                LabeledContent("Sessies", value: "\(days.count)")
                LabeledContent("Totaal sets", value: "\(sets.count)")
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.headline)
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
