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

    /// Per spiergroep, sterkste groep eerst. De kleur stond al op elke kaart maar deed
    /// niets; als kop maakt hij de lijst scanbaar zonder dat je elk woord moet lezen.
    private func grouped(_ records: [Record]) -> [(muscle: String, records: [Record])] {
        Dictionary(grouping: records, by: \.muscle)
            .map { (muscle: $0.key, records: $0.value.sorted { $0.e1rm > $1.e1rm }) }
            .sorted { ($0.records.first?.e1rm ?? 0) > ($1.records.first?.e1rm ?? 0) }
    }

    var body: some View {
        // `records` liep over de volledige sets-tabel en werd vier keer per render
        // opgevraagd (titel, telling, leeg-check, ForEach). Nu één keer.
        let records = records
        let prCount = records.filter(\.recentPR).count
        return ScrollView {
            LazyVStack(spacing: 14) {
                BuiltScreenTitle(eyebrow: "Records",
                                 title: records.isEmpty ? "Nog leeg" : "\(records.count) oefeningen") {
                    if prCount > 0 {
                        Label("\(prCount) vers", systemImage: "trophy.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.builtTint(.orange), in: Capsule())
                            .accessibilityLabel("\(prCount) verse PR's in de laatste 2 weken")
                    }
                }
                if records.isEmpty {
                    ContentUnavailableView("Nog geen records", systemImage: "trophy",
                                           description: Text("Vink je eerste sets af — dan verschijnen hier je PR's."))
                        .builtCard()
                }
                ForEach(grouped(records), id: \.muscle) { group in
                    BuiltSectionHeader(group.muscle)
                    VStack(spacing: 0) {
                        ForEach(Array(group.records.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().padding(.leading, 15) }
                            recordRow(r)
                        }
                    }
                    .builtCard(padding: 0)
                }
                BuiltFootnote("1RM is geschat uit je beste set (Epley). Tik een oefening voor je hele historie.")
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .tabBarClearance()
        // Bewust géén verborgen navigatiebalk: dit scherm wordt gepusht, en de balk is
        // de enige terugweg — verbergen nam ook de swipe-terug mee.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Eén regel per oefening: naam, de twee andere records klein eronder, e1RM groot
    /// rechts. Zeven kaarten van drie kolommen waren twee schermen scrollen zonder dat
    /// één getal eruit sprong.
    private func recordRow(_ r: Record) -> some View {
        let tint = Color.muscle(r.muscle)
        return NavigationLink {
            ExerciseDetailView(exercise: r.name)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if r.recentPR {
                            Text("PR").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text("beste set \(r.topWeight.kgText) kg · sessie \(r.bestVolume) kg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(r.e1rm.kgText) kg")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("1RM").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }
}
