import SwiftUI

// PROTOTYPE — weggooicode, hoort niet op main.
//
// Drie varianten van de oefeningkiezer op één scherm, wisselbaar via de zwarte balk
// onderin. Vraag die dit moet beantwoorden: **wanneer wordt een oefening toegevoegd, en
// hoe zie je dat?** De huidige versie voegt toe bij de tik en laat alleen een vinkje
// achter — te weinig feedback, "Annuleer" liegt, en het toetsenbord blijft staan.
//
// Draaien: `-pickerPrototype` als launch-argument (zie RootView). Geen account nodig,
// geen SwiftData: de oefeningen hieronder zijn verzonnen en niets wordt opgeslagen.
//
// De drie zijn het oneens over de kern:
//   A — kiezen is nog niet toevoegen; onderbalk bevestigt.
//   B — toevoegen gebeurt meteen, maar je ziet je training groeien en kunt terug.
//   C — de rij is geen knop meer; een plusje regelt hoe váák je hem toevoegt.

#if DEBUG

private struct FakeExercise: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let muscle: String
    let type: String
}

private let fakeCatalog: [FakeExercise] = [
    .init(name: "Bench Press", muscle: "Borst", type: "Barbell"),
    .init(name: "Incline Dumbbell Press", muscle: "Borst", type: "Dumbbell"),
    .init(name: "Cable Fly", muscle: "Borst", type: "Kabel"),
    .init(name: "Push-up", muscle: "Borst", type: "Bodyweight"),
    .init(name: "Deadlift", muscle: "Rug", type: "Barbell"),
    .init(name: "Barbell Row", muscle: "Rug", type: "Barbell"),
    .init(name: "Lat Pulldown", muscle: "Rug", type: "Kabel"),
    .init(name: "Pull-up", muscle: "Rug", type: "Bodyweight"),
    .init(name: "Seated Row", muscle: "Rug", type: "Kabel"),
    .init(name: "Shoulder Press", muscle: "Schouders", type: "Dumbbell"),
    .init(name: "Lateral Raises", muscle: "Schouders", type: "Dumbbell"),
    .init(name: "Face Pulls", muscle: "Schouders", type: "Kabel"),
    .init(name: "Squat", muscle: "Benen", type: "Barbell"),
    .init(name: "Leg Press", muscle: "Benen", type: "Machine"),
    .init(name: "Romanian Deadlift", muscle: "Benen", type: "Barbell"),
    .init(name: "Leg Curl", muscle: "Benen", type: "Machine"),
    .init(name: "Leg Extension", muscle: "Benen", type: "Machine"),
    .init(name: "Calf Raises", muscle: "Benen", type: "Machine"),
    .init(name: "Biceps Curl", muscle: "Armen", type: "Dumbbell"),
    .init(name: "Hammer Curl", muscle: "Armen", type: "Dumbbell"),
    .init(name: "Triceps Pushdown", muscle: "Armen", type: "Kabel"),
    .init(name: "Skull Crusher", muscle: "Armen", type: "Barbell"),
    .init(name: "Plank", muscle: "Core", type: "Bodyweight"),
    .init(name: "Hanging Leg Raise", muscle: "Core", type: "Bodyweight"),
    .init(name: "Roeien", muscle: "Cardio", type: "Cardio"),
]

private func matches(_ query: String, _ muscle: String?) -> [FakeExercise] {
    fakeCatalog.filter { ex in
        (muscle == nil || ex.muscle == muscle)
            && (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
    }
}

// MARK: - Root

struct PickerPrototypeView: View {
    @State private var variant = "A"
    /// Wat er in de "training" terecht is gekomen — de staat waar het om draait.
    @State private var addedToWorkout: [String] = ["Bench Press", "Lateral Raises"]
    @State private var showPicker = true

    private let variants = ["A", "B", "C"]
    private let titles = ["A": "Winkelmandje", "B": "Live training", "C": "Aantal per rij"]

    var body: some View {
        stubWorkout
            .sheet(isPresented: $showPicker) {
                Group {
                    switch variant {
                    case "B": VariantB(added: $addedToWorkout)
                    case "C": VariantC(added: $addedToWorkout)
                    default: VariantA(added: $addedToWorkout)
                    }
                }
                .interactiveDismissDisabled()
                .overlay(alignment: .bottom) { switcher }
            }
    }

    /// De achtergrond waar de kiezer overheen komt: net genoeg om de dichtheid te laten
    /// kloppen, verder niet interessant.
    private var stubWorkout: some View {
        NavigationStack {
            List {
                Section("Push A · 12:04") {
                    ForEach(addedToWorkout, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline)
                            Text("3 sets · 60 kg × 8").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Oefening toevoegen") { showPicker = true }
                }
            }
            .navigationTitle("Training")
        }
    }

    private var switcher: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                VStack(spacing: 1) {
                    Text("PROTOTYPE").font(.system(size: 8, weight: .heavy)).opacity(0.5)
                    Text("\(variant) — \(titles[variant] ?? "")").font(.footnote.bold())
                }
                .frame(width: 150)
                Button { cycle(1) } label: { Image(systemName: "chevron.right") }
            }
            // Rule: laat de staat zien. Dit is wat er nú in de training staat.
            Text(addedToWorkout.isEmpty ? "training is leeg" : addedToWorkout.joined(separator: ", "))
                .font(.system(size: 9, design: .monospaced))
                .opacity(0.7)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.88), in: Capsule())
        .shadow(radius: 12)
        .padding(.bottom, 6)
    }

    private func cycle(_ step: Int) {
        guard let i = variants.firstIndex(of: variant) else { return }
        let next = (i + step + variants.count) % variants.count
        withAnimation(.snappy(duration: 0.2)) {
            variant = variants[next]
            addedToWorkout = ["Bench Press", "Lateral Raises"] // schone lei per variant
        }
    }
}

// MARK: - A: kiezen is nog niet toevoegen

/// Tikken selecteert. Onderin staat wat je gaat toevoegen en een knop die het doet.
/// "Annuleer" mag hier bestaan, want er is nog niets gebeurd — precies de klacht.
/// Toetsenbord verdwijnt zodra je scrollt.
private struct VariantA: View {
    @Binding var added: [String]
    @State private var query = ""
    @State private var muscle: String?
    @State private var picked: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches(query, muscle)) { ex in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if let i = picked.firstIndex(of: ex.name) { picked.remove(at: i) }
                            else { picked.append(ex.name) }
                        }
                    } label: {
                        HStack {
                            ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
                            Image(systemName: picked.contains(ex.name) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked.contains(ex.name) ? Color.green : Color.secondary.opacity(0.4))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(picked.contains(ex.name) ? Color.green.opacity(0.08) : nil)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Zoek oefening")
            .navigationTitle("Oefeningen kiezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") {} }
                ToolbarItem(placement: .topBarTrailing) { MuscleFilterMenu(selection: $muscle) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !picked.isEmpty {
                        Text(picked.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button {
                        added.append(contentsOf: picked)
                        picked = []
                    } label: {
                        Text(picked.isEmpty ? "Kies eerst een oefening" : "\(picked.count) toevoegen")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(picked.isEmpty)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 78) // ruimte voor de prototype-balk
                .background(.bar)
            }
        }
    }
}

// MARK: - B: meteen toevoegen, maar je ziet het gebeuren

/// Toevoegen gebeurt bij de tik (zoals nu), maar bovenin groeit de training mee: chips
/// met wat erin staat, elk met een kruisje om het terug te draaien. Nooit "Annuleer" —
/// alleen "Klaar". Toetsenbord gaat weg met een knop boven het toetsenbord.
private struct VariantB: View {
    @Binding var added: [String]
    @State private var query = ""
    @State private var muscle: String?

    private func chip(_ index: Int, _ name: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption.bold())
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    added = added.enumerated().filter { $0.offset != index }.map(\.element)
                }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.builtTint(.green), in: Capsule())
        .foregroundStyle(.green)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(added.enumerated()), id: \.offset) { i, name in
                    chip(i, name)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func row(_ ex: FakeExercise) -> some View {
        let n = added.filter { $0 == ex.name }.count
        return Button {
            withAnimation(.snappy(duration: 0.2)) { added.append(ex.name) }
        } label: {
            HStack {
                ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
                if n > 0 {
                    Text(n == 1 ? "in training" : "\(n)× in training")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !added.isEmpty { chips }
                List {
                    ForEach(matches(query, muscle)) { ex in
                        row(ex)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .searchable(text: $query, prompt: "Zoek oefening")
            .navigationTitle(added.isEmpty ? "Oefening toevoegen" : "\(added.count) in je training")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { MuscleFilterMenu(selection: $muscle) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar") {}.font(.body.bold())
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Gereed") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                    .font(.body.bold())
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 78) }
        }
    }
}

// MARK: - C: de rij is geen knop, het plusje wel

/// De rij zelf doet niets meer (tikken opent straks de detailweergave). Rechts staat een
/// plusje dat één keer toevoegt; nog een keer tikken maakt er 2× van, want dezelfde
/// oefening twee keer in één training mag. Onderin één bevestiging.
private struct VariantC: View {
    @Binding var added: [String]
    @State private var query = ""
    @State private var muscle: String?
    @State private var counts: [String: Int] = [:]

    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches(query, muscle)) { ex in
                    HStack(spacing: 12) {
                        ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
                        if let n = counts[ex.name], n > 0 {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    if n <= 1 { counts[ex.name] = nil } else { counts[ex.name] = n - 1 }
                                }
                            } label: {
                                Image(systemName: "minus.circle").font(.title3).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            Text("\(n)×")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.green)
                                .frame(minWidth: 24)
                        }
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { counts[ex.name, default: 0] += 1 }
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Zoek oefening")
            .navigationTitle("Oefeningen kiezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") {} }
                ToolbarItem(placement: .topBarTrailing) { MuscleFilterMenu(selection: $muscle) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    for (name, n) in counts { added.append(contentsOf: Array(repeating: name, count: n)) }
                    counts = [:]
                } label: {
                    Text(total == 0 ? "Nog niets gekozen" : "\(total) oefening\(total == 1 ? "" : "en") toevoegen")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(total == 0)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 78)
                .background(.bar)
            }
        }
    }
}

#endif
