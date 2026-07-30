import SwiftUI
import SwiftData
import Charts

struct WeightView: View {
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \Scale.name) private var scales: [Scale]
    @Query(sort: \PhotoEntry.date, order: .reverse) private var photos: [PhotoEntry]

    @State private var showLogSheet = false
    @State private var periodDays = 90
    @State private var scrubDate: Date?
    @State private var editEntry: WeightEntry?
    @State private var editText = ""

    private var cal: Calendar { .current }

    // MARK: - Data

    private var chartWeights: [WeightEntry] {
        let cutoff = Date.now.addingTimeInterval(-Double(periodDays) * 86_400)
        let filtered = weights.filter { $0.date > cutoff }
        return filtered.isEmpty ? weights : filtered
    }

    private var showPoints: Bool { periodDays < 36_500 } // op "Alles" alleen de trendlijn

    private var multiScale: Bool {
        weights.contains { !$0.scale.isEmpty }
    }

    private var movingAvg: [(date: Date, kg: Double)] {
        chartWeights.map { w in
            let window = weights.filter { $0.date > w.date.addingTimeInterval(-7 * 86_400) && $0.date <= w.date }
            return (w.date, window.map(\.kg).reduce(0, +) / Double(window.count))
        }
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

    private var yDomain: ClosedRange<Double> {
        var vals = chartWeights.map(\.kg) + [profile.goalWeight, profile.startWeight]
        if let projection { vals += projection.points.map(\.kg) }
        let low = vals.min() ?? 0
        let high = vals.max() ?? 1
        let pad = max((high - low) * 0.15, 0.8)
        return (low - pad)...(high + pad)
    }

    private var scrubbedEntry: WeightEntry? {
        guard let scrubDate else { return nil }
        return chartWeights.min { abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate)) }
    }

    /// Metingen gegroepeerd per maand, nieuwste eerst.
    private var monthGroups: [(month: Date, entries: [WeightEntry])] {
        let groups = Dictionary(grouping: weights) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date
        }
        return groups
            .map { (month: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.month > $1.month }
    }

    private func delta(for entry: WeightEntry) -> Double? {
        guard let previous = weights.last(where: { $0.date < entry.date }) else { return nil }
        return entry.kg - previous.kg
    }

    // MARK: - Body

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    @ViewBuilder private var content: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    headTile("Start", profile.startWeight.kgText)
                    Divider()
                    headTile("Huidig", current?.kgText ?? "—")
                    Divider()
                    headTile("Verschil",
                             current.map { "\($0 - profile.startWeight >= 0 ? "+" : "")\(($0 - profile.startWeight).kgText)" } ?? "—",
                             color: current.map { ($0 - profile.startWeight) * (profile.goalWeight - profile.startWeight) >= 0 ? .green : .orange })
                }
                Button {
                    showLogSheet = true
                } label: {
                    Label("Nieuwe meting", systemImage: "plus.circle.fill")
                        .font(.headline)
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
                chart
                legend
                if weights.count < 5 {
                    Text("Weeg jezelf ±2 weken dagelijks, dan wordt de trendlijn betrouwbaar.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let projection {
                    Label(projection.text, systemImage: "flag.checkered")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Inzicht") {
                if let trend = weights.trendPerWeek {
                    Label {
                        Text("Trend: \(trend >= 0 ? "+" : "")\(trend.formatted(.number.precision(.fractionLength(2)))) kg/week — doel \(profile.weeklyRate >= 0 ? "+" : "")\(profile.weeklyRate.formatted(.number.precision(.fractionLength(2))))")
                    } icon: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(abs(trend - profile.weeklyRate) < 0.1 ? .green : .secondary)
                    }
                    .font(.footnote)
                    scheduleRow
                } else {
                    Text("Log minimaal twee weken gewicht voor een betrouwbare trend.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    PhotosView()
                } label: {
                    HStack(spacing: 12) {
                        if let photo = photos.first, let ui = UIImage(contentsOfFile: photo.fileURL.path) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 36, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: BuiltRadius.small))
                        } else {
                            Image(systemName: "camera")
                                .foregroundStyle(.secondary)
                                .frame(width: 36)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Progress foto's")
                            if let last = photos.first {
                                Text("Laatste: \(last.date.formatted(.dateTime.day().month()))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            ForEach(monthGroups, id: \.month) { group in
                Section(group.month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(group.entries) { entry in
                        Button { editEntry = entry; editText = entry.kg.kgText } label: { entryRow(entry) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(group.entries[i]) }
                    }
                }
            }
        }
        .navigationTitle("Gewicht")
        .toolbar {
            Button("Wegen", systemImage: "plus") { showLogSheet = true }
        }
        .sheet(isPresented: $showLogSheet) { WeightLogSheet() }
        .alert("Weging aanpassen", isPresented: Binding(get: { editEntry != nil }, set: { if !$0 { editEntry = nil } })) {
            TextField("kg", text: $editText).keyboardType(.decimalPad)
            Button("Opslaan") {
                if let e = editEntry, let v = Double(editText.replacingOccurrences(of: ",", with: ".")), v > 0 { e.kg = v }
                editEntry = nil
            }
            Button("Annuleer", role: .cancel) { editEntry = nil }
        }
        .sensoryFeedback(.increase, trigger: weights.count) { old, new in new > old }
    }

    // MARK: - Onderdelen

    private func headTile(_ label: String, _ value: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color ?? .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var chart: some View {
        Chart {
            if showPoints {
                ForEach(chartWeights) { w in
                    PointMark(x: .value("Datum", w.date), y: .value("Gewicht", w.kg))
                        .foregroundStyle(by: .value("Weegschaal", multiScale ? (w.scale.isEmpty ? "Onbekend" : w.scale) : "Gewicht"))
                        .opacity(0.55)
                }
            }
            ForEach(movingAvg, id: \.date) { p in
                LineMark(x: .value("Datum", p.date), y: .value("Trend", p.kg),
                         series: .value("Serie", "Trend"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if let projection {
                ForEach(projection.points, id: \.date) { p in
                    LineMark(x: .value("Datum", p.date), y: .value("Gewicht", p.kg),
                             series: .value("Serie", "Projectie"))
                        .foregroundStyle(.green.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            RuleMark(y: .value("Doel", profile.goalWeight))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("Doel \(profile.goalWeight.kgText) kg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            if let scrubbed = scrubbedEntry {
                RuleMark(x: .value("Datum", scrubbed.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("Datum", scrubbed.date), y: .value("Gewicht", scrubbed.kg))
                    .foregroundStyle(.green)
                    .symbolSize(90)
                    .annotation(position: .top) {
                        VStack(spacing: 0) {
                            Text("\(scrubbed.kg.kgText) kg").font(.caption.bold().monospacedDigit())
                            Text(scrubbed.date.formatted(.dateTime.day().month()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartForegroundStyleScale(range: [Color.green, .orange, .purple, .cyan, .pink])
        .chartLegend(.hidden)
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
                                    scrubDate = date
                                }
                            }
                            .onEnded { _ in scrubDate = nil }
                    )
            }
        }
        .frame(height: 240)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.3), value: periodDays)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .green, label: "7-daags gemiddelde")
            if projection != nil {
                legendItem(color: .green.opacity(0.5), label: "projectie")
            }
            legendItem(color: .secondary.opacity(0.7), label: "doel")
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 14, height: 2)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scheduleRow: some View {
        Group {
            if abs(profile.weeklyRate) > 0.01, let cur = current {
                let daysAhead = Int(((cur - profile.startWeight) - profile.expectedGain) / profile.weeklyRate * 7)
                if daysAhead >= 1 {
                    Label("Je ligt \(daysAhead) dagen voor op schema.", systemImage: "calendar.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if daysAhead <= -1 {
                    Label("Je ligt \(-daysAhead) dagen achter op schema.", systemImage: "calendar.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Precies op schema. 🎯", systemImage: "calendar.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func entryRow(_ entry: WeightEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cal.component(.hour, from: entry.date) < 12 ? "sun.max" : "moon")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            Text("\(entry.kg.kgText) kg")
                .font(.body.weight(.semibold))
                .monospacedDigit()
            if let d = delta(for: entry), abs(d) > 0.01 {
                Text("\(d >= 0 ? "+" : "")\(d.formatted(.number.precision(.fractionLength(1))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(d * (profile.goalWeight - profile.startWeight) >= 0 ? .green : .orange)
            }
            Spacer()
            if !entry.scale.isEmpty {
                Text(entry.scale)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Text(entry.date.formatted(.dateTime.day().month().hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct WeightLogSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Scale.name) private var scales: [Scale]
    @AppStorage("lastScale") private var selectedScale = ""
    @State private var kgText = ""
    @State private var date: Date
    @State private var showAddScale = false
    @State private var newScaleName = ""

    init(initialDate: Date = .now) {
        _date = State(initialValue: initialDate)
    }

    private static let addTag = "\u{0}+"  // sentinel voor "Weegschaal toevoegen"

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
                DatePicker("Datum", selection: $date, in: ...Date.now, displayedComponents: .date)
                Picker("Weegschaal", selection: $selectedScale) {
                    Text("Geen").tag("")
                    ForEach(scales) { s in
                        Text(s.name).tag(s.name)
                    }
                    Label("Weegschaal toevoegen", systemImage: "plus").tag(Self.addTag)
                }
                .onChange(of: selectedScale) { old, new in
                    if new == Self.addTag { selectedScale = old; showAddScale = true }
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
                        let entryDate = Calendar.current.isDateInToday(date)
                            ? Date.now
                            : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
                        context.insert(WeightEntry(date: entryDate, kg: kg ?? 0, scale: selectedScale))
                        dismiss()
                    }
                    .disabled((kg ?? 0) < 20)
                }
            }
        }
        .presentationDetents([.height(320)])
        .alert("Nieuwe weegschaal", isPresented: $showAddScale) {
            TextField("Naam (bijv. Badkamer)", text: $newScaleName)
            Button("Toevoegen") {
                let name = newScaleName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    context.insert(Scale(name: name))
                    selectedScale = name
                }
                newScaleName = ""
            }
            Button("Annuleer", role: .cancel) { newScaleName = "" }
        }
        .onAppear {
            if !scales.map(\.name).contains(selectedScale) { selectedScale = "" }
        }
    }
}
