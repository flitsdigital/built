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
    @Query(sort: \PhotoEntry.date, order: .reverse) private var photos: [PhotoEntry]

    @State private var showLogSheet = false
    @State private var periodDays = 90
    @State private var scrubDate: Date?
    @State private var editEntry: WeightEntry?

    private var cal: Calendar { .current }

    // MARK: - Data

    private var cutoff: Date { Date.now.addingTimeInterval(-Double(periodDays) * 86_400) }

    private var chartWeights: [WeightEntry] {
        let filtered = weights.filter { $0.date > cutoff }
        return filtered.isEmpty ? weights : filtered
    }

    private var showPoints: Bool { periodDays < 36_500 } // op "Alles" alleen de trendlijn

    private var multiScale: Bool {
        weights.contains { !$0.scale.isEmpty }
    }

    /// Vast, en over álle wegingen — niet alleen de zichtbare. Leidt Charts het domein zelf
    /// af, dan hangt de kleur van een weegschaal af van wie er toevallig in beeld staat, en
    /// wisselen de bolletjes van kleur zodra je van 1 maand naar 3 maanden gaat.
    private var scaleDomain: [String] {
        guard multiScale else { return ["Gewicht"] }
        return Set(weights.map { $0.scale.isEmpty ? "Onbekend" : $0.scale }).sorted()
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

    /// Het venster dat de periodekiezer aanwijst. Zonder eigen domein rekt Charts de x-as
    /// op tot de verste mark — de projectie loopt een half jaar vooruit, en dan zag je van
    /// "1 mnd" niets terug.
    private var xDomain: ClosedRange<Date> {
        let start = max(cutoff, chartWeights.first?.date ?? cutoff)
        // Ruimte rechts voor de projectie, maar nooit zo veel dat de metingen wegvallen.
        let ahead = projection == nil ? 0 : min(Double(periodDays) * 0.25, 45) * 86_400
        let end = Date.now.addingTimeInterval(ahead)
        return end > start ? start...end : start...start.addingTimeInterval(86_400)
    }

    private var yDomain: ClosedRange<Double> {
        var vals = chartWeights.map(\.kg)
        if let projection { vals += projection.points.map(\.kg) }
        let low = vals.min() ?? profile.goalWeight
        let high = vals.max() ?? profile.goalWeight
        // Het doel mag de as niet platdrukken: ligt het meer dan een meetbereik weg, dan
        // blijft het buiten beeld en vertelt de projectieregel het verhaal.
        let span = max(high - low, 1)
        let lo = profile.goalWeight > low - span ? min(low, profile.goalWeight) : low
        let hi = profile.goalWeight < high + span ? max(high, profile.goalWeight) : high
        let pad = max((hi - lo) * 0.15, 0.8)
        return (lo - pad)...(hi + pad)
    }

    private var showsGoal: Bool { yDomain.contains(profile.goalWeight) }

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
            if weights.isEmpty {
                // Een statrij met drie streepjes en een lege grafiek is geen scherm maar
                // een formulier dat op je wacht. Eén uitnodiging is genoeg.
                Section {
                    ContentUnavailableView {
                        Label("Nog geen wegingen", systemImage: "scalemass")
                    } description: {
                        Text("Weeg je 's ochtends, dan tekent de trendlijn na een week je richting — losse dagen zeggen niets.")
                    } actions: {
                        Button("Eerste weging") { showLogSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    HStack(spacing: 0) {
                        StatTile(value: profile.startWeight.kgText, label: "Start", size: .compact)
                        Divider()
                        // "Huidig" las als "wat de weegschaal vanochtend zei"; het is het
                        // 7-daags gemiddelde. Zelfde getal, eerlijk label.
                        StatTile(value: current?.kgText ?? "—", label: "Gem. 7d", size: .compact)
                        Divider()
                        StatTile(value: current.map { "\($0 - profile.startWeight >= 0 ? "+" : "")\(($0 - profile.startWeight).kgText)" } ?? "—",
                                 label: "Verschil", size: .compact,
                                 tint: current.map { ($0 - profile.startWeight) * (profile.goalWeight - profile.startWeight) >= 0 ? .green : .orange })
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
                                .accessibilityHidden(true)
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
                        Button { editEntry = entry } label: { entryRow(entry) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { context.deleteSynced(group.entries[i]) }
                    }
                }
            }
        }
        .navigationTitle("Gewicht")
        .toolbar {
            Button("Wegen", systemImage: "plus") { showLogSheet = true }
        }
        .sheet(isPresented: $showLogSheet) { WeightLogSheet() }
        .sheet(item: $editEntry) { WeightLogSheet(entry: $0) }
        .sensoryFeedback(.increase, trigger: weights.count) { old, new in new > old }
    }

    // MARK: - Onderdelen

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
                AreaMark(x: .value("Datum", p.date),
                         yStart: .value("Onder", yDomain.lowerBound),
                         yEnd: .value("Trend", p.kg))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.22), .green.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
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
            if showsGoal {
                RuleMark(y: .value("Doel", profile.goalWeight))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Doel \(profile.goalWeight.kgText) kg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: periodDays <= 90
                               ? Date.FormatStyle.dateTime.day().month(.abbreviated)
                               : Date.FormatStyle.dateTime.month(.abbreviated).year(.twoDigits))
            }
        }
        .chartForegroundStyleScale(domain: scaleDomain, range: [Color.green, .orange, .purple, .cyan, .pink])
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
            if showsGoal { legendItem(color: .secondary.opacity(0.7), label: "doel") }
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
                .accessibilityHidden(true) // het tijdstip staat rechts al voluit in de rij
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

/// Wegen, en een weging terug bewerken. Dat laatste was een alert met alleen een
/// kg-veld — datum en weegschaal lagen vast zodra je had opgeslagen.
struct WeightLogSheet: View {
    var entry: WeightEntry?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Scale.name) private var scales: [Scale]
    @AppStorage("lastScale") private var lastScale = ""
    @State private var selectedScale: String
    @State private var kgText: String
    @State private var date: Date
    @State private var showAddScale = false
    @State private var newScaleName = ""

    init(entry: WeightEntry? = nil, initialDate: Date = .now) {
        self.entry = entry
        _date = State(initialValue: entry?.date ?? initialDate)
        _kgText = State(initialValue: entry.map { $0.kg.kgText } ?? "")
        // Bij bewerken telt de weegschaal van die meting, niet de laatstgebruikte.
        _selectedScale = State(initialValue: entry?.scale
                               ?? UserDefaults.standard.string(forKey: "lastScale") ?? "")
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
            .navigationTitle(entry == nil ? "Wegen" : "Weging aanpassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") {
                        // 9:00 voor een terug-gelogde weging: die doe je 's ochtends.
                        let entryDate = timestamp(on: date, hour: 9)
                        if let entry {
                            entry.kg = kg ?? entry.kg
                            entry.scale = selectedScale
                            // Zelfde dag = zelfde tijdstip: een ochtendweging hoort niet
                            // naar 9:00 te schuiven omdat je het gewicht corrigeerde.
                            if dayKey(date) != dayKey(entry.date) { entry.date = entryDate }
                        } else {
                            context.insert(WeightEntry(date: entryDate, kg: kg ?? 0, scale: selectedScale))
                        }
                        lastScale = selectedScale
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
