#if DEBUG
import SwiftUI

// PROTOTYPE — WEGGOOIWERK. Geen tests, geen SwiftData, geen productiecode.
// Vier open vragen, elk met varianten via de balk onderaan.
// Starten: xcrun simctl launch <udid> com.jordiklavers.Built -prototype
// Zie branch prototype/ui-varianten; wat we kiezen gaat daarna pas de echte code in.

struct PrototypeGallery: View {
    enum Question: String, CaseIterable, Identifiable {
        case routine = "3 · Routine"
        case empty = "6 · Lege staat"
        case shape = "8 · Vormtaal"
        case stats = "9 · Statcijfers"
        var id: String { rawValue }

        static var fromLaunch: Question {
            switch UserDefaults.standard.integer(forKey: "vraag") {
            case 6: .empty
            case 8: .shape
            case 9: .stats
            default: .routine
            }
        }
    }

    // `simctl launch … -prototype -vraag 8 -variant 2` opent meteen die variant; het
    // -sleutel-waarde-paar landt vanzelf in UserDefaults.
    @State private var question: Question = .fromLaunch
    @State private var variant = UserDefaults.standard.integer(forKey: "variant")

    private var variants: [String] {
        switch question {
        case .routine: ["Laatste set", "Zwaarste set", "Eerste set", "Zonder doelen"]
        case .empty: ["Nu", "ContentUnavailable", "Kaart met voorbeeld"]
        case .shape: ["Nu (lijst)", "Kaartkop", "Alles kaarten"]
        case .stats: ["regular (nu)", "large", "hero"]
        }
    }

    /// Wat deze variant aanneemt — de "state" die zichtbaar hoort te zijn.
    private var rule: String {
        switch (question, variant) {
        case (.routine, 0): "sets = wat je deed, reps = je laatste set (je vermoeide set)"
        case (.routine, 1): "reps van je zwaarste set — het doel is het gewicht dat telt"
        case (.routine, 2): "reps van je eerste set — fris, dus het hoogste getal"
        case (.routine, 3): "alleen de oefeningen in volgorde; doelen vul je zelf in"
        case (.empty, 0): "zoals het nu is: lege grafiek + grijze zin, geen knop"
        case (.empty, 1): "ContentUnavailableView: icoon, kop, één regel, knop"
        case (.empty, 2): "de kaart ís de uitnodiging, met een vervaagde voorbeeldgrafiek"
        case (.shape, 0): "List-formulier, zoals SessionDetailView nu is"
        case (.shape, 1): "kaartkop met de cijfers, de rest blijft lijst"
        case (.shape, 2): "alles kaarten, zoals de Training-tab"
        case (.stats, 0): "StatTile .regular — .title2"
        case (.stats, 1): "StatTile .large — .title"
        case (.stats, 2): "hero — 34pt rounded, label klein eronder"
        default: ""
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch question {
                case .routine: RoutinePrototype(variant: variant)
                case .empty: EmptyStatePrototype(variant: variant)
                case .shape: ShapePrototype(variant: variant)
                case .stats: StatsPrototype(variant: variant)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Prototype")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Vraag", selection: $question) {
                        ForEach(Question.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .onChange(of: question) { variant = 0 }
            .safeAreaInset(edge: .bottom) { bar }
        }
    }

    private var bar: some View {
        VStack(spacing: 6) {
            Text(rule)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { i, name in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { variant = i }
                        } label: {
                            Text(name)
                                .font(.footnote.weight(variant == i ? .bold : .regular))
                                .foregroundStyle(variant == i ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(variant == i ? Color.green : Color(.tertiarySystemFill), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

// MARK: - 3 · Welke routine rolt uit een training?

private struct PSet { let kg: Double; let reps: Int }
private struct PExercise { let name: String; let sets: [PSet] }

private let sampleSession: [PExercise] = [
    .init(name: "Bankdrukken", sets: [.init(kg: 60, reps: 10), .init(kg: 60, reps: 9), .init(kg: 62.5, reps: 8)]),
    .init(name: "Incline dumbbell press", sets: [.init(kg: 22, reps: 12), .init(kg: 22, reps: 10), .init(kg: 24, reps: 8)]),
    .init(name: "Kabel fly", sets: [.init(kg: 15, reps: 15), .init(kg: 15, reps: 14)]),
    .init(name: "Triceps pushdown", sets: [.init(kg: 30, reps: 12), .init(kg: 30, reps: 12), .init(kg: 32, reps: 10)]),
]

private struct RoutinePrototype: View {
    let variant: Int

    private func target(_ e: PExercise) -> String? {
        switch variant {
        case 0: "\(e.sets.count) × \(e.sets.last?.reps ?? 0)"
        case 1: "\(e.sets.count) × \(e.sets.max { $0.kg < $1.kg }?.reps ?? 0)"
        case 2: "\(e.sets.count) × \(e.sets.first?.reps ?? 0)"
        default: nil
        }
    }

    var body: some View {
        List {
            Section("De training van dinsdag") {
                ForEach(sampleSession, id: \.name) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.subheadline.bold())
                        Text(e.sets.map { "\($0.kg.formatted())×\($0.reps)" }.joined(separator: "  "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "arrow.down").foregroundStyle(.green)
                    Text("Maak routine van deze training").font(.subheadline.bold())
                }
            }

            Section {
                LabeledContent("Naam") { Text("Push A").foregroundStyle(.secondary) }
                ForEach(sampleSession, id: \.name) { e in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name)
                            if let t = target(e) {
                                Text(t).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("4 oefeningen · 11 sets — de nieuwe routine")
            } footer: {
                Text(variant == 3
                     ? "Zonder doelen is de routine een boodschappenlijstje: je ziet tijdens de training wel wat je vorige keer deed."
                     : "Het doel staat er meteen in, dus de volgende keer weet je waar je op mikt.")
            }
        }
    }
}

// MARK: - 6 · Lege staat (Gewicht, nul metingen)

private struct EmptyStatePrototype: View {
    let variant: Int

    var body: some View {
        List {
            switch variant {
            case 0:
                Section {
                    HStack(spacing: 0) {
                        StatTile(value: "—", label: "Start", size: .compact)
                        Divider()
                        StatTile(value: "—", label: "Gem. 7d", size: .compact)
                        Divider()
                        StatTile(value: "—", label: "Verschil", size: .compact)
                    }
                    Button { } label: { Label("Nieuwe meting", systemImage: "plus.circle.fill").font(.headline) }
                }
                Section {
                    emptyPlot(ghost: false)
                    Text("Weeg jezelf ±2 weken dagelijks, dan wordt de trendlijn betrouwbaar.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            case 1:
                Section {
                    ContentUnavailableView {
                        Label("Nog geen wegingen", systemImage: "scalemass")
                    } description: {
                        Text("Weeg je 's ochtends, dan tekent de trendlijn na een week je richting — losse dagen zeggen niets.")
                    } actions: {
                        Button("Eerste weging") { }.buttonStyle(.borderedProminent).tint(.green)
                    }
                    .listRowBackground(Color.clear)
                }
            default:
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        emptyPlot(ghost: true)
                        Text("Zo ziet je trend eruit")
                            .font(.headline)
                        Text("Na ±7 wegingen staat hier jouw lijn. Losse dagen springen; de trend niet.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button { } label: {
                            Label("Eerste weging", systemImage: "plus")
                                .font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func emptyPlot(ghost: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: BuiltRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
            if ghost {
                GeometryReader { geo in
                    Path { p in
                        let pts: [Double] = [0.62, 0.55, 0.6, 0.48, 0.5, 0.4, 0.34, 0.3]
                        for (i, v) in pts.enumerated() {
                            let x = geo.size.width * Double(i) / Double(pts.count - 1)
                            let y = geo.size.height * v
                            i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                        }
                    }
                    .stroke(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .padding(20)
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in Divider(); Spacer() }
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(height: 180)
    }
}

// MARK: - 8 · Vormtaal van het sessiescherm

private struct ShapePrototype: View {
    let variant: Int

    private var stats: some View {
        HStack {
            StatTile(value: "48 min", label: "duur")
            StatTile(value: "4820", label: "kg volume")
            StatTile(value: "11", label: "sets")
        }
    }

    private var delta: some View {
        Text("+240 kg volume t.o.v. je vorige training")
            .font(.footnote).foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    var body: some View {
        switch variant {
        case 0:
            List {
                Section { stats; delta }
                Section("Training") {
                    LabeledContent("Datum") { Text("dinsdag 19 aug").foregroundStyle(.secondary) }
                    Text("Push A").foregroundStyle(.secondary)
                }
                Section("Records") { Text("🏆 Bankdrukken: e1RM 79,1 kg (was 76,4)").font(.subheadline.bold()) }
                Section("Bankdrukken") { setRows }
            }
        case 1:
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text("Push A").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        stats
                        delta
                        Text("🏆 Bankdrukken: e1RM 79,1 kg (was 76,4)")
                            .font(.footnote.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .builtCard()
                    VStack(spacing: 0) {
                        BuiltSectionHeader("Bankdrukken")
                        setRows
                    }
                }
                .padding(.horizontal)
            }
        default:
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text("Push A").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        stats
                        delta
                    }
                    .builtCard()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🏆 Nieuw record").font(.caption.bold()).foregroundStyle(.orange)
                        Text("Bankdrukken: e1RM 79,1 kg (was 76,4)").font(.subheadline)
                    }
                    .builtCard()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bankdrukken").font(.headline)
                        setRows
                    }
                    .builtCard()
                }
                .padding(.horizontal)
            }
        }
    }

    private var setRows: some View {
        ForEach(Array([(60.0, 10), (60.0, 9), (62.5, 8)].enumerated()), id: \.offset) { i, s in
            HStack(spacing: 12) {
                Text("\(i + 1)").font(.subheadline.monospacedDigit().bold()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(s.0.formatted()).frame(width: 64, height: 32)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                Text("kg").font(.footnote).foregroundStyle(.secondary)
                Text("\(s.1)").frame(width: 52, height: 32)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                Text("reps").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 9 · Hoe groot mag een statcijfer zijn?

private struct StatsPrototype: View {
    let variant: Int

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    Text("Push A").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    row([("48 min", "duur"), ("4820", "kg volume"), ("11", "sets")])
                }
                .builtCard()

                VStack(spacing: 10) {
                    Text("Gewicht").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    row([("78,4", "Start"), ("76,1", "Gem. 7d"), ("−2,3", "Verschil")])
                }
                .builtCard()

                Text("Let op de bovenste rij: \"48 min\" is de langste waarde en breekt het eerst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }

    private func row(_ items: [(value: String, label: String)]) -> some View {
        HStack {
            ForEach(items, id: \.label) { value, label in
                switch variant {
                case 0: StatTile(value: value, label: label, size: .regular)
                case 1: StatTile(value: value, label: label, size: .large)
                default: hero(value, label)
                }
            }
        }
    }

    private func hero(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
