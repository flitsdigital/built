import SwiftUI
import SwiftData

/// PR-muur: beste geschat 1RM, beste gewicht en beste sessievolume per oefening.
struct RecordsView: View {
    @Query(sort: \SetEntry.date) private var sets: [SetEntry]
    @Query private var exercises: [Exercise]

    private var cal: Calendar { .current }

    private struct Record: Identifiable {
        let name: String
        let muscle: String
        let e1rm: Double
        let topWeight: Double
        let bestVolume: Int
        let recentPR: Bool
        var id: String { name }
    }

    private var records: [Record] {
        let muscleOf = Dictionary(exercises.map { ($0.name, $0.muscle) }, uniquingKeysWith: { a, _ in a })
        let typeOf = Dictionary(exercises.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        var out: [Record] = []
        // ponytail: cardio kent geen 1RM/gewicht — hoort niet op de PR-muur
        for (name, group) in Dictionary(grouping: sets, by: \.exercise) where typeOf[name] != "Cardio" {
            let e1rm = group.map { epley($0.weightKg, $0.reps) }.max() ?? 0
            let topWeight = group.map(\.weightKg).max() ?? 0
            let byDay = Dictionary(grouping: group) { dayKey($0.date) }
            let bestVolume = byDay.values.map { day in Int(day.map { $0.weightKg * Double($0.reps) }.reduce(0, +)) }.max() ?? 0
            // Recente PR? beste e1RM van de laatste sessie > alles ervoor, en die
            // sessie hoogstens 14 dagen oud (anders blijft de badge eeuwig staan).
            let days = byDay.keys.sorted()
            var recentPR = false
            if let last = days.last, days.count >= 2, dayKey(.now) - last <= 14 {
                let lastBest = (byDay[last] ?? []).map { epley($0.weightKg, $0.reps) }.max() ?? 0
                let before = group.filter { dayKey($0.date) < last }.map { epley($0.weightKg, $0.reps) }.max() ?? 0
                recentPR = before > 0 && lastBest > before + 0.1
            }
            out.append(Record(name: name, muscle: muscleOf[name] ?? "Overig",
                              e1rm: e1rm, topWeight: topWeight, bestVolume: bestVolume, recentPR: recentPR))
        }
        return out.sorted { $0.e1rm > $1.e1rm }
    }

    var body: some View {
        // `records` liep over de volledige sets-tabel en werd vier keer per render
        // opgevraagd (titel, telling, leeg-check, ForEach). Nu één keer.
        let records = records
        let prCount = records.filter(\.recentPR).count
        return ScrollView {
            LazyVStack(spacing: 14) {
                BuiltScreenTitle("Records", records.isEmpty ? "Nog leeg" : "\(records.count) oefeningen")
                if prCount > 0 {
                    Label("\(prCount) verse \(prCount == 1 ? "PR" : "PR's") in de laatste 2 weken",
                          systemImage: "trophy.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .builtCard()
                }
                if records.isEmpty {
                    ContentUnavailableView("Nog geen records", systemImage: "trophy",
                                           description: Text("Vink je eerste sets af — dan verschijnen hier je PR's."))
                        .builtCard()
                }
                ForEach(records) { r in
                    recordCard(r)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .tabBarClearance()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func recordCard(_ r: Record) -> some View {
        let tint = Color.muscle(r.muscle)
        return NavigationLink {
            ExerciseDetailView(exercise: r.name)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 18)
                    Text(r.name).font(.headline).foregroundStyle(.primary)
                    if r.recentPR {
                        Text("PR").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(r.muscle.uppercased())
                        .font(.caption2.weight(.semibold)).tracking(0.6)
                        .foregroundStyle(tint)
                }
                HStack(spacing: 0) {
                    recordStat("1RM", "\(r.e1rm.kgText) kg", "🏆")
                    recordStat("Gewicht", "\(r.topWeight.kgText) kg", nil)
                    recordStat("Volume", "\(r.bestVolume) kg", nil)
                }
            }
            .builtCard()
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private func recordStat(_ label: String, _ value: String, _ badge: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)\(badge.map { " \($0)" } ?? "")")
                .font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
