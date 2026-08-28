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
    /// Uit de kiezers en de bibliotheek, maar de rij blijft bestaan. Verwijderen wiste 'm
    /// echt, en omdat sets op naam koppelen viel al dat volume daarna onder "Overig" in
    /// Volume per spiergroep — de historie was dus stilletjes van spiergroep veranderd.
    var archived: Bool = false

    init(name: String, muscle: String = Exercise.muscles.last!, type: String = Exercise.types.last!,
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
            // Cardio hoort bij de standaardcatalogus.
            for name in cardioSeed where !known.contains(name) { seedRow(name, "Cardio", "Cardio") }
        }
        // Cardio kwam later — eenmalig bijplaatsen bij installs van vóór die versie.
        //
        // De vlag lijkt overbodig naast de `where`, maar is het niet: zonder vlag draait
        // dit elke start, en dan komt een cardio-oefening die je zélf weggooide er telkens
        // weer bij — mét dezelfde afgeleide id als de tombstone die je verwijdering
        // achterliet. De rest van de catalogus zaait alleen bij een lege lijst en heeft
        // dat probleem niet.
        if !UserDefaults.standard.bool(forKey: "seededCardio") {
            UserDefaults.standard.set(true, forKey: "seededCardio")
            for name in cardioSeed where !known.contains(name) { seedRow(name, "Cardio", "Cardio") }
        }

        // Vrije-tekst-oefeningen uit historie en routines opnemen als "Overig"
        let usedInSets = (try? context.fetch(FetchDescriptor<SetEntry>()))?.map(\.exercise) ?? []
        let usedInRoutines = (try? context.fetch(FetchDescriptor<Routine>()))?.flatMap(\.exercises) ?? []
        for name in Set(usedInSets + usedInRoutines) where !known.contains(name) {
            context.insert(Exercise(name: name))
            known.insert(name)
        }
    }

    /// Eén rij per naam, met het van die naam afgeleide id.
    ///
    /// Oefeningen van vóór het afgeleide id kregen `UUID()`, en sinds de pull samenvoegt in
    /// plaats van vervangt staat dezelfde naam daarna twee keer in de lijst: de rij van het
    /// oude toestel én de rij die een nieuwer toestel zelf zaaide. Er hangt niets aan het
    /// overtollige exemplaar — sets en routines koppelen op naam, niet op id — dus dat mag
    /// gewoon weg, mét tombstone zodat de server het ook opruimt.
    ///
    /// Wie blijft is bewust niet "de oudste": twee toestellen die verschillend kiezen wissen
    /// elkaars keuze weg en houden niets over. `UUID.stable(from:)` valt overal hetzelfde
    /// uit, dus komt elk toestel op dezelfde rij uit. Draait na elke pull — een duplicaat dat
    /// alsnog binnenkomt lost zichzelf zo op.
    @MainActor
    static func dedupe(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        for (name, rows) in Dictionary(grouping: all, by: \.name) where !name.isEmpty {
            let id = UUID.stable(from: name)
            guard let keeper = rows.first(where: { $0.syncID == id })
                    ?? rows.min(by: { $0.createdAt < $1.createdAt }) else { continue }
            for row in rows where row !== keeper { context.deleteSynced(row) }
            guard keeper.syncID != id else { continue }
            if keeper.syncID != .zero {
                Sync.recordDeletion(table: Exercise.syncTable, syncID: keeper.syncID)
            }
            keeper.syncID = id
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

/// Iets dat het type van een oefening kent. De trainingsschermen bouwen er een dict van
/// (O(1), en ze vragen het per set); andere schermen hebben gewoon de `@Query`-array. De
/// vragen zijn dezelfde, dus staan de antwoorden hier één keer.
protocol ExerciseTypes {
    func type(of name: String) -> String?
}

extension ExerciseTypes {
    /// Bodyweight-oefening? Dan is het gewicht optioneel extra gewicht ("+kg").
    func isBodyweight(_ name: String) -> Bool { type(of: name) == "Bodyweight" }
    /// Barbell-oefening? Dan tonen we de schijven-per-kant.
    func isBarbell(_ name: String) -> Bool { type(of: name) == "Barbell" }
    /// Cardio? Dan log je duur i.p.v. kg × reps.
    func isCardio(_ name: String) -> Bool { type(of: name) == "Cardio" }
}

extension Array: ExerciseTypes where Element == Exercise {
    func type(of name: String) -> String? { first { $0.name == name }?.type }
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
            Spacer(minLength: 0)
        }
        // De rij vult de breedte en vángt hem ook: zonder dit is alleen de tekst tikbaar
        // en gebeurt er rechts van de naam niets.
        .contentShape(Rectangle())
    }
}

/// Filter op spiergroep. Staat in de toolbar van zowel de kiezer als de bibliotheek.
struct MuscleFilterMenu: View {
    @Binding var selection: String?

    var body: some View {
        Menu {
            Button("Alle spiergroepen") { selection = nil }
            Divider()
            ForEach(Exercise.muscles, id: \.self) { m in
                Button {
                    selection = m
                } label: {
                    if selection == m { Label(m, systemImage: "checkmark") } else { Text(m) }
                }
            }
        } label: {
            Image(systemName: selection == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(selection ?? "Alle spiergroepen")
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
    @Query private var sets: [SetEntry]
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var creating = false
    /// Wat je hebt aangevinkt, in de volgorde waarin je het aanvinkte — zo landen ze ook
    /// in je training. Kiezen is nog niet toevoegen: dat gebeurt pas bij de knop onderin,
    /// en daarom mag "Annuleer" hier ook echt annuleren.
    @State private var selected: [String] = []
    /// Welke oefening je voortgang van bekijkt via de ⓘ.
    @State private var detail: ExerciseName?

    private var filtered: [Exercise] {
        exercises.filter { ex in
            !ex.archived && !exclude.contains(ex.name)
                && (muscleFilter == nil || ex.muscle == muscleFilter)
                && (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// Je acht meest gelogde oefeningen van het laatste kwartaal, bovenaan.
    ///
    /// De catalogus telt er ruim honderd en jij gebruikt er twintig; alfabetisch betekende
    /// dat je bij elke training langs Crosstrainer scrolde om bij Leg Extension te komen.
    /// Alleen als je niet zoekt en niet filtert — dan heb je zelf al gezegd wat je zoekt.
    private var frequent: [Exercise] {
        guard query.isEmpty, muscleFilter == nil else { return [] }
        let cutoff = Date.now.addingTimeInterval(-90 * 86_400)
        var counts: [String: Int] = [:]
        for s in sets where s.date >= cutoff { counts[s.exercise, default: 0] += 1 }
        return exercises
            .filter { !$0.archived && !exclude.contains($0.name) && (counts[$0.name] ?? 0) > 0 }
            .sorted { (counts[$0.name] ?? 0, $1.name) > (counts[$1.name] ?? 0, $0.name) }
            .prefix(8)
            .map { $0 }
    }

    /// Eén rij in de kiezer. Staat apart omdat "Vaak gebruikt" en "Alle oefeningen"
    /// dezelfde rij tonen.
    private func pickerRow(_ ex: Exercise) -> some View {
        let isPicked = selected.contains(ex.name)
        return HStack(spacing: 8) {
            Button {
                toggle(ex.name)
            } label: {
                ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isPicked ? [.isSelected] : [])
            // De rechterkant is van de ⓘ: hier zoek je uit wélke oefening je kiest, en dan
            // wil je erbij kunnen zonder eerst aan te vinken. Een knop en geen
            // NavigationLink — die zet er in een List zelf een chevron achter, en dan staat
            // de ⓘ ineens midden in de rij.
            Button {
                detail = ExerciseName(ex.name)
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voortgang van \(ex.name)")
        }
        // De rijkleur draagt de selectie nu alleen; de bevestigbalk onderin noemt ze bij
        // naam, dus kleur is niet het enige signaal.
        .listRowBackground(isPicked ? Color.green.opacity(0.18) : nil)
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
                let often = frequent
                if !often.isEmpty {
                    Section("Vaak gebruikt") {
                        ForEach(often) { pickerRow($0) }
                    }
                }
                Section {
                    ForEach(filtered) { pickerRow($0) }
                } header: {
                    if !often.isEmpty { Text("Alle oefeningen") }
                }
                if filtered.isEmpty && !query.isEmpty {
                    Button {
                        creating = true
                    } label: {
                        Label("\u{201C}\(query)\u{201D} toevoegen", systemImage: "plus")
                    }
                }
            }
            // Het toetsenbord blijft anders over de lijst hangen zodra je gezocht hebt,
            // en er is geen andere weg om het weg te krijgen.
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Zoek oefening")
            .navigationTitle("Oefeningen kiezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    MuscleFilterMenu(selection: $muscleFilter)
                }
            }
            .navigationDestination(item: $detail) { item in
                ExerciseDetailView(exercise: item.name)
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .animation(.snappy(duration: 0.25), value: selected.isEmpty)
            .sheet(isPresented: $creating) {
                // Net aangemaakt is nog niet toegevoegd: hij komt in je mandje, zodat je
                // in één bevestiging afsluit in plaats van in twee.
                NewExerciseSheet(presetName: query) { name in
                    toggle(name)
                }
            }
        }
    }

    /// Verschijnt pas als er iets te bevestigen valt — een lege balk is chroom dat de
    /// lijst korter maakt zonder iets te zeggen.
    @ViewBuilder private var confirmBar: some View {
        if !selected.isEmpty {
            VStack(spacing: 8) {
                Text(selected.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head) // de laatst gekozen blijft in beeld
                Button {
                    for name in selected { onPick(name) }
                    dismiss()
                } label: {
                    Text("\(selected.count) toevoegen")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func toggle(_ name: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if let i = selected.firstIndex(of: name) { selected.remove(at: i) } else { selected.append(name) }
        }
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
    @Query private var sets: [SetEntry]
    @State private var query = ""
    @State private var muscleFilter: String?
    @State private var creating = false

    private var filtered: [Exercise] {
        exercises.filter { ex in
            !ex.archived
                && (muscleFilter == nil || ex.muscle == muscleFilter)
                && (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var archived: [Exercise] { exercises.filter(\.archived) }

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
                        // Naar de voortgang, niet naar het formulier: kijken doe je vaker
                        // dan hernoemen. Bewerken zit rechtsboven op het detailscherm.
                        NavigationLink {
                            ExerciseDetailView(exercise: ex.name)
                        } label: {
                            ExerciseRow(name: ex.name, muscle: nil, type: ex.type)
                        }
                    }
                    // Geen `onDelete`: verwijderen wiste de rij, en omdat sets op naam
                    // koppelen viel al dat volume daarna onder "Overig".
                    .onDelete { offsets in
                        for i in offsets { group.items[i].archived = true }
                    }
                }
            }
            if !archived.isEmpty {
                Section {
                    ForEach(archived) { ex in
                        HStack {
                            ExerciseRow(name: ex.name, muscle: ex.muscle, type: ex.type)
                            Spacer()
                            Button("Terug") { ex.archived = false }
                                .font(.footnote.bold())
                                .buttonStyle(.plain)
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Gearchiveerd")
                } footer: {
                    Text("Uit de kiezers, maar je historie telt gewoon mee bij de juiste spiergroep.")
                }
            }
        }
        .tabBarClearance()
        .searchable(text: $query, prompt: "Zoek oefening")
        .navigationTitle("Oefeningen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MuscleFilterMenu(selection: $muscleFilter)
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
        .tabBarClearance()
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
