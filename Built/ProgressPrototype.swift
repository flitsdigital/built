import SwiftUI
import Charts

// PROTOTYPE — weggooicode, hoort niet op main.
//
// Loopt het pad na dat we hebben afgesproken: je staat midden in een training, ziet onder
// de oefeningnaam dat er iets te melden valt, tikt erop en krijgt je verloop. Plus de
// kiezer met een ⓘ per rij en de groene rijkleur als selectiestaat.
//
// De ingangen zelf zijn loodgieterswerk en staan hier alleen om het pad te kunnen lopen.
// Wat écht een keuze is, is het **kopblok** van het detailscherm: bij Q16 spraken we af
// dat vier gelijkwaardige regels één groot getal worden, maar niet hoe dat eruitziet.
// Daar zijn drie varianten van, wisselbaar via de zwarte balk onderin.
//
// Draaien: `-progressPrototype` als launch-argument. Geen account nodig; de sets hieronder
// zijn verzonnen en er wordt niets opgeslagen.

#if DEBUG

private struct FakeSet: Identifiable {
    let id = UUID()
    let date: Date
    let kg: Double
    let reps: Int
    var e1rm: Double { epley(kg, reps) }
}

/// Veertien sessies bankdrukken die netjes oplopen en dan drie sessies blijven hangen —
/// zo zie je zowel een stijgende grafiek als het plateau waar de trendregel op afgaat.
private let fakeSets: [FakeSet] = {
    let cal = Calendar.current
    let kgPerSession: [Double] = [60, 60, 62.5, 62.5, 65, 65, 67.5, 70, 70, 72.5, 75, 75, 75, 75]
    var out: [FakeSet] = []
    for (i, kg) in kgPerSession.enumerated() {
        let day = cal.date(byAdding: .day, value: -(kgPerSession.count - i) * 5, to: .now) ?? .now
        out.append(FakeSet(date: day, kg: kg - 5, reps: 10))
        out.append(FakeSet(date: day, kg: kg, reps: 8))
        out.append(FakeSet(date: day, kg: kg, reps: i % 3 == 0 ? 7 : 6))
    }
    return out
}()

private var fakeSessions: [(day: Date, sets: [FakeSet])] {
    Dictionary(grouping: fakeSets) { Calendar.current.startOfDay(for: $0.date) }
        .map { ($0.key, $0.value.sorted { $0.kg < $1.kg }) }
        .sorted { $0.0 > $1.0 }
}

private var bestE1RM: Double { fakeSets.map(\.e1rm).max() ?? 0 }
private var bestWeight: Double { fakeSets.map(\.kg).max() ?? 0 }

/// Beste e1RM per sessie, oplopend — voedt zowel de grafiek als de trendregel.
private var e1rmPerSession: [(day: Date, kg: Double)] {
    fakeSessions.map { ($0.day, $0.sets.map(\.e1rm).max() ?? 0) }.sorted { $0.0 < $1.0 }
}

/// Dezelfde regel als `plateauedLifts`: geen nieuw 1RM-record in de laatste 3 sessies,
/// vanaf 5 sessies historie. Anders: een record in de laatste 30 dagen.
private var headerNote: (text: String, warning: Bool)? {
    let vals = e1rmPerSession.map(\.kg)
    guard vals.count >= 5 else { return nil }
    let prior = vals.dropLast(3).max() ?? 0
    let recent = vals.suffix(3).max() ?? 0
    if recent <= prior * 1.005 {
        return ("3 sessies geen record — probeer reps te verlagen", true)
    }
    let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    let before = e1rmPerSession.filter { $0.day < monthAgo }.map(\.kg).max() ?? 0
    guard before > 0 else { return nil }
    return ("+\((recent - before).kgText) kg 1RM deze maand", false)
}

// MARK: - Wisselbalk (ook boven een sheet, anders kun je niet vergelijken)

private struct PrototypeSwitcher: View {
    @Binding var variant: String
    static let variants = ["A", "B", "C"]
    static let titles = ["A": "Eén groot getal", "B": "Getal met verloop", "C": "Twee getallen"]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                VStack(spacing: 1) {
                    Text("PROTOTYPE · KOPBLOK").font(.system(size: 8, weight: .heavy)).opacity(0.5)
                    Text("\(variant) — \(Self.titles[variant] ?? "")").font(.footnote.bold())
                }
                .frame(width: 165)
                Button { cycle(1) } label: { Image(systemName: "chevron.right") }
            }
            Text("1RM \(bestE1RM.kgText) · top \(bestWeight.kgText) · \(fakeSessions.count) sessies")
                .font(.system(size: 9, design: .monospaced))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.88), in: Capsule())
        .shadow(radius: 12)
        .padding(.bottom, 6)
    }

    private func cycle(_ step: Int) {
        guard let i = Self.variants.firstIndex(of: variant) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            variant = Self.variants[(i + step + Self.variants.count) % Self.variants.count]
        }
    }
}

// MARK: - Root

struct ProgressPrototypeView: View {
    @State private var variant = "A"
    @State private var showDetail = false
    @State private var showPicker = false

    private let variants = ["A", "B", "C"]
    private let titles = ["A": "Eén groot getal", "B": "Getal met verloop", "C": "Twee getallen"]

    var body: some View {
        NavigationStack {
            List {
                Section("Push A · 12:04") {
                    exerciseHeader
                    setRow(1, "62,5 kg × 8")
                    setRow(2, "62,5 kg × 6")
                }
                Section {
                    Button("Oefening toevoegen") { showPicker = true }
                }
                Section {
                    Text("Tik op de oefeningnaam hierboven voor het detailscherm. De ⓘ in de kiezer doet hetzelfde.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Training")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 80) }
        }
        .overlay(alignment: .bottom) { PrototypeSwitcher(variant: $variant) }
        .sheet(isPresented: $showDetail) {
            DetailPrototype(variant: $variant)
                .overlay(alignment: .bottom) { PrototypeSwitcher(variant: $variant) }
        }
        .sheet(isPresented: $showPicker) {
            PickerPrototypeRows(variant: $variant)
                .overlay(alignment: .bottom) { PrototypeSwitcher(variant: $variant) }
        }
    }

    /// De kop van een oefening in de lopende training: naam tikbaar, en eronder de regel
    /// die er alleen staat als er iets te melden valt.
    private var exerciseHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                showDetail = true
            } label: {
                HStack(spacing: 4) {
                    Text("Bench Press").font(.headline).foregroundStyle(.green)
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            if let note = headerNote {
                Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(note.warning ? .orange : .green)
            }
            Label("Vorige keer: 72,5 kg × 8", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func setRow(_ n: Int, _ text: String) -> some View {
        HStack {
            Text("\(n)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.subheadline)
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

}

// MARK: - Detailscherm, met het kopblok als variant

private struct DetailPrototype: View {
    @Binding var variant: String
    /// Gepusht binnen de kiezer (Q19) heeft hij geen eigen stack en geen sluitknop nodig;
    /// als sheet vanuit de training wél.
    var pushed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if pushed { content } else { NavigationStack { content } }
    }

    private var content: some View {
        List {
                Section { summary.listRowBackground(Color.clear) }
                Section("Verloop") {
                    Chart(e1rmPerSession, id: \.day) { item in
                        LineMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .foregroundStyle(.green)
                    .frame(height: 180)
                    .padding(.vertical, 8)
                }
                Section("Historie") {
                    ForEach(fakeSessions.prefix(6), id: \.day) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.day.formatted(.dateTime.day().month(.abbreviated).year()))
                                .font(.subheadline.bold())
                            Text(session.sets.map { "\($0.kg.kgText)×\($0.reps)" }.joined(separator: "   "))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        .navigationTitle("Bench Press")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pushed {
                ToolbarItem(placement: .cancellationAction) { Button("Sluit") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Bewerk") {} }
        }
    }

    @ViewBuilder private var summary: some View {
        switch variant {
        case "B": variantB
        case "C": variantC
        default: variantA
        }
    }

    /// A — één groot getal, de rest als voetnoot. Maximale nadruk op "ben ik sterker".
    private var variantA: some View {
        VStack(spacing: 6) {
            Text("Geschat 1RM").font(.caption).foregroundStyle(.secondary)
            Text("\(bestE1RM.kgText) kg").font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
            HStack(spacing: 16) {
                small("Topgewicht", "\(bestWeight.kgText) kg")
                small("Sessies", "\(fakeSessions.count)")
                small("Sets", "\(fakeSets.count)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// B — hetzelfde getal, maar met de beweging erbij: hoeveel en sinds wanneer.
    private var variantB: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(bestE1RM.kgText)").font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text("kg").font(.headline).foregroundStyle(.secondary)
                    Text("geschat 1RM").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Chart(e1rmPerSession.suffix(8), id: \.day) { item in
                    LineMark(x: .value("Dag", item.day), y: .value("kg", item.kg))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .foregroundStyle(.green)
                .frame(width: 90, height: 40)
            }
            if let note = headerNote {
                Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "arrow.up.right")
                    .font(.footnote.bold())
                    .foregroundStyle(note.warning ? .orange : .green)
            }
            Text("Top \(bestWeight.kgText) kg · \(fakeSessions.count) sessies · \(fakeSets.count) sets")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// C — twee getallen naast elkaar: de formule en het gevoel, zonder dat er één wint.
    private var variantC: some View {
        HStack(spacing: 0) {
            big("Geschat 1RM", bestE1RM.kgText)
            Divider().frame(height: 44)
            big("Topgewicht", bestWeight.kgText)
        }
        .overlay(alignment: .bottom) {
            Text("\(fakeSessions.count) sessies · \(fakeSets.count) sets")
                .font(.caption2).foregroundStyle(.secondary).offset(y: 14)
        }
        .padding(.vertical, 8)
        .padding(.bottom, 12)
    }

    private func big(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value) kg").font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity)
    }

    private func small(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Kiezer: groene rijkleur als selectiestaat, ⓘ rechts

private struct PickerPrototypeRows: View {
    @Binding var variant: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var showInfo = false

    private let rows = [("Bench Press", "Borst", "Barbell"), ("Incline Dumbbell Press", "Borst", "Dumbbell"),
                        ("Cable Fly", "Borst", "Kabel"), ("Deadlift", "Rug", "Barbell"),
                        ("Barbell Row", "Rug", "Barbell"), ("Squat", "Benen", "Barbell")]

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows, id: \.0) { name, muscle, type in
                    let isPicked = selected.contains(name)
                    HStack(spacing: 8) {
                        Button { toggle(name) } label: {
                            ExerciseRow(name: name, muscle: muscle, type: type)
                        }
                        .buttonStyle(.plain)
                        Button { showInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(isPicked ? Color.green.opacity(0.18) : nil)
                }
            }
            .navigationTitle("Oefeningen kiezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    VStack(spacing: 8) {
                        Text(selected.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button {} label: {
                            Text("\(selected.count) toevoegen").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .padding(.horizontal).padding(.top, 10).padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .navigationDestination(isPresented: $showInfo) {
                DetailPrototype(variant: $variant, pushed: true)
            }
        }
    }

    private func toggle(_ name: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if let i = selected.firstIndex(of: name) { selected.remove(at: i) } else { selected.append(name) }
        }
    }
}

#endif
