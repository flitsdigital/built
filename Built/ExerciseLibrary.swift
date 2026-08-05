import SwiftUI
import SwiftData

// MARK: - Model

@Model
final class Exercise {
    var syncID: UUID = UUID.zero
    /// Naam is de sleutel waarmee SetEntry en Routine (beide String) koppelen.
    var name: String
    var muscle: String
    var type: String
    var createdAt: Date
    /// Spieren die meewerken zonder de hoofdrol te spelen. Los van `muscle`, want die
    /// bepaalt waar de oefening in de bibliotheek en de spiersplit terechtkomt — dat blijft
    /// één spier, anders telt een oefening meerdere keren mee in het volume.
    var secondaryMuscles: [String] = []

    init(name: String, muscle: String = Exercise.fallbackMuscle, type: String = Exercise.fallbackType,
         secondaryMuscles: [String] = []) {
        self.syncID = UUID()
        self.name = name
        self.muscle = muscle
        self.type = type
        self.createdAt = .now
        self.secondaryMuscles = secondaryMuscles
    }

    static let muscles = ["Borst", "Rug", "Schouders", "Biceps", "Triceps",
                          "Benen", "Hamstrings", "Bilspieren", "Kuiten", "Core", "Onderrug", "Cardio", "Overig"]
    static let types = ["Barbell", "Dumbbell", "Machine", "Kabel", "Bodyweight", "Kettlebell", "Band", "Cardio", "Overig"]

    /// "Overig" is wat een rij krijgt die nooit is ingedeeld — de default van een nieuwe
    /// oefening, en daarmee het enige dat bij het samenvoegen mag wijken voor de andere rij.
    static var fallbackMuscle: String { muscles.last! }
    static var fallbackType: String { types.last! }

    static let typeIcon = [
        "Barbell": "figure.strengthtraining.traditional",
        "Dumbbell": "dumbbell.fill",
        "Machine": "figure.strengthtraining.functional",
        "Kabel": "figure.rower",
        "Bodyweight": "figure.core.training",
        "Kettlebell": "figure.cross.training",
        "Band": "figure.flexibility",
        "Cardio": "figure.run",
        "Overig": "dumbbell",
    ]

    /// Standaardcatalogus + inhalen van namen die al in de historie/routines staan.
    @MainActor
    static func bootstrap(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        var known = Set(existing.map(\.name))

        // Standaardcatalogus krijgt een van de naam afgeleid id, zodat elk toestel dezelfde
        // rij zaait en een merge-pull er geen tweede exemplaar naast zet. Zie UUID.stable.
        func seedRow(_ name: String, _ muscle: String, _ type: String) {
            let exercise = Exercise(name: name, muscle: muscle, type: type)
            exercise.syncID = .stable(from: name)
            context.insert(exercise)
            known.insert(name)
        }

        if existing.isEmpty {
            for (name, muscle, type) in seed { seedRow(name, muscle, type) }
            // Cardio hoort bij de standaardcatalogus. Het stond alleen achter de vlag
            // hieronder, en die blijft na één keer draaien permanent aan — een toestel dat
            // leeggemaakt werd kreeg z'n cardio-oefeningen daardoor nooit terug.
            for name in cardioSeed where !known.contains(name) { seedRow(name, "Cardio", "Cardio") }
        }
        // Cardio kwam later — eenmalig bijplaatsen bij installs van vóór die versie.
        if !UserDefaults.standard.bool(forKey: "seededCardio") {
            UserDefaults.standard.set(true, forKey: "seededCardio")
            for name in cardioSeed where !known.contains(name) { seedRow(name, "Cardio", "Cardio") }
        }

        // Vrije-tekst-oefeningen uit historie en routines opnemen als "Overig". Ook dit is
        // een rij die de app zelf zaait — twee toestellen met dezelfde training halen
        // dezelfde naam op — dus ook hier een afgeleid id in plaats van `UUID()`.
        let usedInSets = (try? context.fetch(FetchDescriptor<SetEntry>()))?.map(\.exercise) ?? []
        let usedInRoutines = (try? context.fetch(FetchDescriptor<Routine>()))?.flatMap(\.exercises) ?? []
        for name in Set(usedInSets + usedInRoutines) where !known.contains(name) {
            seedRow(name, fallbackMuscle, fallbackType)
        }

        // Wat er vóór deze versie al dubbel stond, staat er nog steeds dubbel.
        dedupe(context)
    }

    /// Twee rijen met dezelfde naam zijn altijd dezelfde oefening — sets en routines
    /// koppelen op naam, dus verder kán de app ze niet uit elkaar houden. Deze pass voegt
    /// ze samen tot één.
    ///
    /// Ze bestaan omdat de standaardcatalogus vóór #43 met `UUID()` gezaaid werd: wie toen
    /// al op twee toestellen zat, heeft op de server twee rijen per oefening staan, en
    /// sinds de pull samenvoegt in plaats van vervangt komen die allebei binnen. Het
    /// afgeleide id voorkomt nieuwe dubbelen maar ruimt de bestaande niet op; dat is dit.
    ///
    /// Samenvoegen, niet "de tweede wissen": wat de ene rij weet en de andere niet gaat
    /// mee naar de blijver, en de verliezer verdwijnt mét tombstone — zonder dat spoor
    /// staat hij er na de volgende pull gewoon weer.
    ///
    /// Welke rij blijft, moet op elk toestel hetzelfde uitvallen. Kiest toestel A rij X en
    /// toestel B rij Y, dan wist ieder de ander en houd je er nul over. De regel kijkt
    /// daarom alleen naar de rijen zelf, nooit naar volgorde of tijdstip: het van de naam
    /// afgeleide id wint, en anders het laagste id. Twee toestellen komen daar los van
    /// elkaar op uit, en een derde rij die later binnenkomt verandert die uitkomst niet.
    @MainActor
    static func dedupe(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        var merged = false
        for (name, rows) in Dictionary(grouping: all, by: \.name) where rows.count > 1 {
            let derived = UUID.stable(from: name)
            let ranked = rows.sorted { a, b in
                if (a.syncID == derived) != (b.syncID == derived) { return a.syncID == derived }
                // Een rij zonder id kan de server niet aanwijzen: de slechtst denkbare blijver.
                if (a.syncID == .zero) != (b.syncID == .zero) { return b.syncID == .zero }
                return a.syncID.uuidString < b.syncID.uuidString
            }
            let keeper = ranked[0]
            for loser in ranked.dropFirst() {
                absorb(loser, into: keeper)
                context.deleteSynced(loser)
                merged = true
            }
        }
        // Zelf opslaan in plaats van op de autosave wachten: de sync houdt bij wélke rijen
        // er wijzigen via de save-melding, en die moet bij de verwijdering horen.
        if merged { try? context.save() }
    }

    /// Alleen schrijven als er echt iets verandert: elke toewijzing is een wijziging die de
    /// sync moet pushen, en dit draait bij elke start en na elke pull.
    private static func absorb(_ loser: Exercise, into keeper: Exercise) {
        if loser.createdAt < keeper.createdAt { keeper.createdAt = loser.createdAt }
        if keeper.muscle == fallbackMuscle, loser.muscle != fallbackMuscle { keeper.muscle = loser.muscle }
        if keeper.type == fallbackType, loser.type != fallbackType { keeper.type = loser.type }
        let extra = loser.secondaryMuscles.filter { !keeper.secondaryMuscles.contains($0) }
        if !extra.isEmpty { keeper.secondaryMuscles.append(contentsOf: extra) }
    }

    private static let cardioSeed = ["Loopband", "Hardlopen", "Fietsen", "Hometrainer",
                                     "Roeimachine", "Crosstrainer", "Stairmaster", "Wandelen"]

    private static let seed: [(String, String, String)] = [
        ("Bench Press", "Borst", "Barbell"),
        ("Incline Dumbbell Press", "Borst", "Dumbbell"),
        ("Dumbbell Press", "Borst", "Dumbbell"),
        ("Chest Fly", "Borst", "Kabel"),
        ("Push Up", "Borst", "Bodyweight"),
        ("Shoulder Press", "Schouders", "Barbell"),
        ("Overhead Press", "Schouders", "Barbell"),
        ("Lateral Raises", "Schouders", "Dumbbell"),
        ("Face Pulls", "Schouders", "Kabel"),
        ("Triceps Pushdown", "Triceps", "Kabel"),
        ("Triceps Extension", "Triceps", "Dumbbell"),
        ("Dips", "Triceps", "Bodyweight"),
        ("Deadlift", "Rug", "Barbell"),
        ("Lat Pulldown", "Rug", "Machine"),
        ("Barbell Row", "Rug", "Barbell"),
        ("Pull Up", "Rug", "Bodyweight"),
        ("Seated Row", "Rug", "Kabel"),
        ("Biceps Curl", "Biceps", "Dumbbell"),
        ("Barbell Curl", "Biceps", "Barbell"),
        ("Hammer Curl", "Biceps", "Dumbbell"),
        ("Squat", "Benen", "Barbell"),
        ("Leg Press", "Benen", "Machine"),
        ("Leg Extension", "Benen", "Machine"),
        ("Lunges", "Benen", "Dumbbell"),
        ("Romanian Deadlift", "Hamstrings", "Barbell"),
        ("Leg Curl", "Hamstrings", "Machine"),
        ("Hip Thrust", "Bilspieren", "Barbell"),
        ("Calf Raises", "Kuiten", "Machine"),
        ("Plank", "Core", "Bodyweight"),
        ("Crunch", "Core", "Bodyweight"),
        ("Hanging Leg Raise", "Core", "Bodyweight"),
    ]
}

extension Array where Element == Exercise {
    /// Bodyweight-oefening? Dan is het gewicht optioneel extra gewicht ("+kg").
    func isBodyweight(_ name: String) -> Bool {
        first { $0.name == name }?.type == "Bodyweight"
    }
    /// Barbell-oefening? Dan tonen we de schijven-per-kant.
    func isBarbell(_ name: String) -> Bool {
        first { $0.name == name }?.type == "Barbell"
    }
    /// Cardio? Dan log je duur i.p.v. kg × reps.
    func isCardio(_ name: String) -> Bool {
        first { $0.name == name }?.type == "Cardio"
    }
}

// MARK: - Rij

struct ExerciseRow: View {
    let name: String
    let muscle: String?
    let type: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.flatMap { Exercise.typeIcon[$0] } ?? "dumbbell")
                .font(.body)
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(.builtTint(.green), in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).foregroundStyle(.primary)
                if let muscle {
                    Text([muscle, type].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Kiezer (herbruikbaar)

/// Kiest een oefening uit de bibliotheek of maakt een nieuwe met spiergroep + type.
struct ExercisePickerSheet: View {
    var exclude: Set<String> = []
    var onPick: (String) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var creating = false

    private var filtered: [Exercise] {
        exercises.filter { ex in
            !exclude.contains(ex.name)
                && (muscleFilter == nil || ex.muscle == muscleFilter)
                && (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        creating = true
                    } label: {
                        Label("Nieuwe oefening", systemImage: "plus.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                ForEach(filtered) { ex in
                    Button {
                        pick(ex.name)
                    } label: {
                        ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty && !query.isEmpty {
                    Button {
                        creating = true
                    } label: {
                        Label("\u{201C}\(query)\u{201D} toevoegen", systemImage: "plus")
                    }
                }
            }
            .searchable(text: $query, prompt: "Zoek oefening")
            .navigationTitle("Oefening kiezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Alle spiergroepen") { muscleFilter = nil }
                        Divider()
                        ForEach(Exercise.muscles, id: \.self) { m in
                            Button {
                                muscleFilter = m
                            } label: {
                                if muscleFilter == m { Label(m, systemImage: "checkmark") } else { Text(m) }
                            }
                        }
                    } label: {
                        Image(systemName: muscleFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityValue(muscleFilter ?? "Alle spiergroepen")
                }
            }
            .sheet(isPresented: $creating) {
                NewExerciseSheet(presetName: query) { name in
                    pick(name)
                }
            }
        }
    }

    private func pick(_ name: String) {
        onPick(name)
        dismiss()
    }
}

/// Nieuwe oefening aanmaken met spiergroep + type.
struct NewExerciseSheet: View {
    var presetName: String = ""
    var onCreate: (String) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var exercises: [Exercise]
    @State private var name = ""
    @State private var muscle = Exercise.muscles.first!
    @State private var type = Exercise.types.first!
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Naam (bijv. Bench Press)", text: $name)
                Picker("Spiergroep", selection: $muscle) {
                    ForEach(Exercise.muscles, id: \.self) { Text($0) }
                }
                Picker("Type", selection: $type) {
                    ForEach(Exercise.types, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Nieuwe oefening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Toevoegen") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if name.isEmpty { name = presetName }
            }
        }
        .presentationDetents([.height(280)])
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if let existing = exercises.first(where: { $0.name == clean }) {
            existing.muscle = muscle
            existing.type = type
        } else {
            context.insert(Exercise(name: clean, muscle: muscle, type: type))
        }
        onCreate(clean)
        dismiss()
    }
}

// MARK: - Beheerscherm

extension Exercise: SyncedRecord {
    static var syncTable: String { "exercises" }
    static func blank() -> Exercise { Exercise(name: "") }
}

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var creating = false

    private var filtered: [Exercise] {
        exercises.filter { ex in
            (muscleFilter == nil || ex.muscle == muscleFilter)
                && (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var byMuscle: [(muscle: String, items: [Exercise])] {
        Exercise.muscles.compactMap { m in
            let items = filtered.filter { $0.muscle == m }
            return items.isEmpty ? nil : (m, items)
        }
    }

    var body: some View {
        List {
            if byMuscle.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nog geen oefeningen" : "Niets gevonden",
                    systemImage: "dumbbell",
                    description: Text(query.isEmpty ? "Voeg je eerste oefening toe met +." : "Geen oefening voor “\(query)”."))
            }
            ForEach(byMuscle, id: \.muscle) { group in
                Section(group.muscle) {
                    ForEach(group.items) { ex in
                        NavigationLink {
                            ExerciseEditor(exercise: ex)
                        } label: {
                            ExerciseRow(name: ex.name, muscle: nil, type: ex.type)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.deleteSynced(group.items[i]) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Zoek oefening")
        .navigationTitle("Oefeningen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Alle spiergroepen") { muscleFilter = nil }
                    Divider()
                    ForEach(Exercise.muscles, id: \.self) { m in
                        Button {
                            muscleFilter = m
                        } label: {
                            if muscleFilter == m { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                } label: {
                    Image(systemName: muscleFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(muscleFilter ?? "Alle spiergroepen")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nieuwe oefening")
            }
        }
        .sheet(isPresented: $creating) {
            NewExerciseSheet { _ in }
        }
    }
}

struct ExerciseEditor: View {
    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var context
    @Query private var sets: [SetEntry]
    @Query private var routines: [Routine]
    @State private var name = ""
    @State private var original = ""

    var body: some View {
        Form {
            TextField("Naam", text: $name)
            Picker("Spiergroep", selection: $exercise.muscle) {
                ForEach(Exercise.muscles, id: \.self) { Text($0) }
            }
            Picker("Type", selection: $exercise.type) {
                ForEach(Exercise.types, id: \.self) { Text($0) }
            }
            Section {
                // Aantikken in plaats van een tweede Picker: het zijn er meestal drie of
                // vier, en een multi-select Picker bestaat niet in SwiftUI.
                ForEach(Exercise.muscles.filter { $0 != exercise.muscle && $0 != "Cardio" }, id: \.self) { m in
                    let on = exercise.secondaryMuscles.contains(m)
                    Button {
                        if on {
                            exercise.secondaryMuscles.removeAll { $0 == m }
                        } else {
                            exercise.secondaryMuscles.append(m)
                        }
                    } label: {
                        HStack {
                            Text(m).foregroundStyle(.primary)
                            Spacer()
                            if on { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                    }
                }
            } header: {
                Text("Meewerkende spieren")
            } footer: {
                Text("Alleen ter informatie: de spiergroep hierboven bepaalt waar de oefening in de bibliotheek en de spiersplit landt.")
            }
        }
        .navigationTitle(name.isEmpty ? exercise.name : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if original.isEmpty { name = exercise.name; original = exercise.name } }
        .onDisappear(perform: commitRename)
    }

    /// Rename pas bij het verlaten (niet per toetsaanslag), en verhuis alle historie
    /// mee — sets/routines koppelen op naam, dus anders raken records en grafieken los.
    private func commitRename() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != original else { return }
        exercise.name = new
        for s in sets where s.exercise == original { s.exercise = new }
        for r in routines {
            r.exercises = r.exercises.map { $0 == original ? new : $0 }
            if let v = r.alternatives.removeValue(forKey: original) { r.alternatives[new] = v }
            if let v = r.targets.removeValue(forKey: original) { r.targets[new] = v }
            if let v = r.supersets.removeValue(forKey: original) { r.supersets[new] = v }
            if let v = r.restByExercise.removeValue(forKey: original) { r.restByExercise[new] = v }
            r.alternatives = r.alternatives.mapValues { list in list.map { $0 == original ? new : $0 } }
        }
        original = new
    }
}
