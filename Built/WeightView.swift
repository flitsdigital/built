import SwiftUI
import SwiftData
import Charts

struct WeightView: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \Scale.name) private var scales: [Scale]

    @State private var showLogSheet = false
    @State private var periodDays = 90

    private var chartWeights: [WeightEntry] {
        let cutoff = Date.now.addingTimeInterval(-Double(periodDays) * 86_400)
        let filtered = weights.filter { $0.date > cutoff }
        return filtered.isEmpty ? weights : filtered
    }

    private var multiScale: Bool {
        weights.contains { !$0.scale.isEmpty }
    }

    private var movingAvg: [(date: Date, kg: Double)] {
        chartWeights.map { w in
            let window = weights.filter { $0.date > w.date.addingTimeInterval(-7 * 86_400) && $0.date <= w.date }
            return (w.date, window.map(\.kg).reduce(0, +) / Double(window.count))
        }
    }

    private var yDomain: ClosedRange<Double> {
        var vals = chartWeights.map(\.kg) + [profile.goalWeight, profile.startWeight]
        if let projection { vals += projection.points.map(\.kg) }
        return (vals.min()! - 1)...(vals.max()! + 1)
    }

    private var current: Double? { weights.average(daysBack: 0..<7) ?? weights.last?.kg }

    /// Doel-projectie: trek de huidige trend door. Alleen als je richting je doel beweegt.
    private var projection: (points: [(date: Date, kg: Double)], text: String)? {
        guard let trend = weights.trendPerWeek, abs(trend) > 0.03, let cur = current else { return nil }
        let remaining = profile.goalWeight - cur
        guard remaining * trend > 0 else { return nil }
        let weeks = remaining / trend
        guard weeks < 156 else { return nil }
        let goalDate = Date.now.addingTimeInterval(weeks * 604_800)
        let capDate = min(goalDate, Date.now.addingTimeInterval(180 * 86_400))
        let capValue = cur + trend * (capDate.timeIntervalSince(.now) / 604_800)
        return ([(Date.now, cur), (capDate, capValue)],
                "Op dit tempo bereik je \(profile.goalWeight.kgText) kg rond \(goalDate.formatted(.dateTime.month(.wide).year())).")
    }

    private var insight: String {
        guard let trend = weights.trendPerWeek else {
            return "Log minimaal twee weken gewicht voor een betrouwbare trend."
        }
        let target = profile.weeklyRate
        var lines = ["Trend: \(trend >= 0 ? "+" : "")\(trend.formatted(.number.precision(.fractionLength(2)))) kg/week (doel \(target >= 0 ? "+" : "")\(target.formatted(.number.precision(.fractionLength(2)))))."]
        if abs(trend - target) < 0.1 {
            lines.append("Perfect op schema. 🎯")
        } else if target > 0 && trend < 0.05 {
            lines.append("Je gewicht stijgt amper. Voeg ±250 kcal per dag toe.")
        } else if target > 0 && trend > target + 0.15 {
            lines.append("Iets sneller dan gepland — hou vetopslag in de gaten.")
        } else {
            lines.append("Prima richting, blijf consistent.")
        }
        if abs(profile.weeklyRate) > 0.01, let cur = current {
            let daysAhead = Int(((cur - profile.startWeight) - profile.expectedGain) / profile.weeklyRate * 7)
            if daysAhead >= 1 { lines.append("Je ligt \(daysAhead) dagen voor op schema.") }
            if daysAhead <= -1 { lines.append("Je ligt \(-daysAhead) dagen achter op schema.") }
        }
        if let projection { lines.append(projection.text) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                if let current {
                    LabeledContent("Huidig (7-daags gem.)", value: "\(current.kgText) kg")
                    LabeledContent("Nog te gaan", value: "\(abs(profile.goalWeight - current).kgText) kg")
                }
            }
            Section {
                Picker("Periode", selection: $periodDays) {
                    Text("1 mnd").tag(30)
                    Text("3 mnd").tag(90)
                    Text("Alles").tag(36_500)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                Chart {
                    ForEach(chartWeights) { w in
                        PointMark(x: .value("Datum", w.date), y: .value("Gewicht", w.kg))
                            .foregroundStyle(by: .value("Weegschaal", multiScale ? (w.scale.isEmpty ? "Onbekend" : w.scale) : "Gewicht"))
                    }
                    ForEach(movingAvg, id: \.date) { p in
                        LineMark(x: .value("Datum", p.date), y: .value("Trend", p.kg),
                                 series: .value("Serie", "Trend"))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.primary)
                    }
                    if let projection {
                        ForEach(projection.points, id: \.date) { p in
                            LineMark(x: .value("Datum", p.date), y: .value("Gewicht", p.kg),
                                     series: .value("Serie", "Projectie"))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                    }
                    RuleMark(y: .value("Doel", profile.goalWeight))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Doel \(profile.goalWeight.kgText) kg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                }
                .chartYScale(domain: yDomain)
                .chartForegroundStyleScale(range: [Color.green, .orange, .purple, .cyan, .pink])
                .chartLegend(multiScale ? .automatic : .hidden)
                .frame(height: 260)
                .padding(.vertical, 8)
            }
            Section("Inzicht") {
                Text(insight)
            }
            Section {
                NavigationLink {
                    PhotosView()
                } label: {
                    Label("Progress foto's", systemImage: "camera")
                }
            }
            Section("Metingen") {
                ForEach(weights.suffix(10).reversed()) { w in
                    LabeledContent {
                        Text("\(w.kg.kgText) kg")
                    } label: {
                        Text(w.date.formatted(date: .abbreviated, time: .shortened))
                        if !w.scale.isEmpty {
                            Text(w.scale).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let visible = Array(weights.suffix(10).reversed())
                    for i in offsets { context.delete(visible[i]) }
                }
            }
        }
        .navigationTitle("Gewicht")
        .toolbar {
            Button("Wegen", systemImage: "plus") { showLogSheet = true }
        }
        .sheet(isPresented: $showLogSheet) { WeightLogSheet() }
    }
}

struct WeightLogSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Scale.name) private var scales: [Scale]
    @AppStorage("lastScale") private var selectedScale = ""
    @State private var kgText = ""

    private var kg: Double? {
        Double(kgText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Gewicht") {
                    TextField("bijv. 70,4", text: $kgText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if !scales.isEmpty {
                    Picker("Weegschaal", selection: $selectedScale) {
                        ForEach(scales) { s in
                            Text(s.name).tag(s.name)
                        }
                    }
                }
            }
            .navigationTitle("Wegen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") {
                        // ponytail: weegschaal-correctie wordt bij opslaan verrekend
                        let offset = scales.first { $0.name == selectedScale }?.offset ?? 0
                        context.insert(WeightEntry(kg: (kg ?? 0) + offset, scale: scales.isEmpty ? "" : selectedScale))
                        dismiss()
                    }
                    .disabled((kg ?? 0) < 20)
                }
            }
        }
        .presentationDetents([.height(280)])
        .onAppear {
            if !scales.map(\.name).contains(selectedScale) {
                selectedScale = scales.first?.name ?? ""
            }
        }
    }
}
