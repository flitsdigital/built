import SwiftUI
import SwiftData

// MARK: - Model

@Model
final class Exercise {
    /// Naam is de sleutel waarmee SetEntry en Routine (beide String) koppelen.
    var name: String
    var muscle: String
    var type: String
    var createdAt: Date

    init(name: String, muscle: String = Exercise.muscles.last!, type: String = Exercise.types.last!) {
        self.name = name
        self.muscle = muscle
        self.type = type
        self.createdAt = .now
    }

    static let muscles = ["Borst", "Rug", "Schouders", "Biceps", "Triceps",
                          "Benen", "Hamstrings", "Bilspieren", "Kuiten", "Core", "Onderrug", "Cardio", "Overig"]
    static let types = ["Barbell", "Dumbbell", "Machine", "Kabel", "Bodyweight", "Kettlebell", "Band", "Cardio", "Overig"]

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
    static func bootstrap(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        var known = Set(existing.map(\.name))

        if existing.isEmpty {
            for (name, muscle, type) in seed {
                context.insert(Exercise(name: name, muscle: muscle, type: type))
                known.insert(name)
            }
        }
        // Cardio kwam later — eenmalig bijplaatsen, ook bij bestaande installs.
        if !UserDefaults.standard.bool(forKey: "seededCardio") {
            UserDefaults.standard.set(true, forKey: "seededCardio")
            for name in cardioSeed where !known.contains(name) {
                context.insert(Exercise(name: name, muscle: "Cardio", type: "Cardio"))
                known.insert(name)
            }
        }

        // Vrije-tekst-oefeningen uit historie en routines opnemen als "Overig"
        let usedInSets = (try? context.fetch(FetchDescriptor<SetEntry>()))?.map(\.exercise) ?? []
        let usedInRoutines = (try? context.fetch(FetchDescriptor<Routine>()))?.flatMap(\.exercises) ?? []
        for name in Set(usedInSets + usedInRoutines) where !known.contains(name) {
            context.insert(Exercise(name: name))
            known.insert(name)
        }
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
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        for i in offsets { context.delete(group.items[i]) }
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
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
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
