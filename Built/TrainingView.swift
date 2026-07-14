import SwiftUI
import SwiftData

struct DraftSet: Identifiable {
    let id = UUID()
    var kg: Double
    var reps: Int
    var done = false
    var previous: String?
    var savedEntry: SetEntry?
}

struct DraftExercise: Identifiable {
    let id = UUID()
    var name: String
    var tip: String?
    var sets: [DraftSet]
    var note = ""
}

struct WorkoutSummary: Identifiable {
    let id = UUID()
    let minutes: Int
    let volume: Int
    let sets: Int
    let prs: [(exercise: String, new: Double, old: Double)]
}

struct TrainingView: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query(sort: \Routine.createdAt) private var routines: [Routine]
    @Query private var habits: [DayHabits]
    @AppStorage("restSeconds") private var restSeconds = 120

    @State private var active = false
    @State private var workout: [DraftExercise] = []
    @State private var startedAt = Date.now
    @State private var summary: WorkoutSummary?
    @State private var editingRoutine: Routine?
    @State private var showNewExercise = false
    @State private var newExerciseName = ""
    @State private var showNewRoutine = false
    @State private var newRoutineName = ""
    @State private var confirmDiscard = false
    @FocusState private var focusedSet: UUID?

    private var cal: Calendar { .current }

    // MARK: - Historie helpers

    private func byExercise(_ daySets: [SetEntry]) -> [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets.sorted(by: { $0.date < $1.date }) where !names.contains(s.exercise) {
            names.append(s.exercise)
        }
        return names.map { n in (n, daySets.filter { $0.exercise == n }.sorted { $0.date < $1.date }) }
    }

    private var pastDays: [Date] {
        let days = Set(sets.map { cal.startOfDay(for: $0.date) })
        return Array(days.sorted(by: >).prefix(90))
    }

    private func sets(on day: Date) -> [SetEntry] {
        sets.filter { cal.isDate($0.date, inSameDayAs: day) }
    }

    private var recentExercises: [String] {
        var names: [String] = []
        for s in sets where !names.contains(s.exercise) {
            names.append(s.exercise)
        }
        return Array(names.prefix(10))
    }

    private func lastSession(for name: String) -> [SetEntry] {
        let prev = sets.filter { $0.exercise == name && $0.date < startedAt }
        guard let latest = prev.first?.date else { return [] }
        return prev.filter { cal.isDate($0.date, inSameDayAs: latest) }.sorted { $0.date < $1.date }
    }

    private var trainedThisWeek: Int {
        let weekStart = cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
        return Set(sets.filter { $0.date > weekStart }.map { cal.startOfDay(for: $0.date) }).count
    }

    // MARK: - Doelgerichte voorstellen (dubbele progressie)

    private func draft(for name: String) -> DraftExercise {
        let last = lastSession(for: name)
        guard !last.isEmpty else {
            return DraftExercise(name: name, tip: "Eerste keer — kies een gewicht dat je 8 reps aankan.",
                                 sets: (0..<3).map { _ in DraftSet(kg: 20, reps: 8) })
        }
        let top = last.map(\.weightKg).max() ?? 20
        let allEight = last.allSatisfy { $0.reps >= 8 }
        let tip = allEight
            ? "Vorige keer alles ≥ 8 reps → vandaag \((top + 2.5).kgText) kg"
            : "Zelfde gewicht, probeer 1 rep meer per set."
        return DraftExercise(name: name, tip: tip, sets: last.map { s in
            DraftSet(kg: allEight ? top + 2.5 : top,
                     reps: allEight ? 8 : min(s.reps + 1, 12),
                     previous: "\(s.weightKg.kgText)×\(s.reps)")
        })
    }

    // PR op geschat 1RM (Epley): 8×60 telt dan ook als record t.o.v. 5×62,5
    private func prInfo(_ ex: DraftExercise) -> (new: Double, old: Double)? {
        guard let doneMax = ex.sets.filter(\.done).map({ epley($0.kg, $0.reps) }).max() else { return nil }
        guard let prev = sets.filter({ $0.exercise == ex.name && $0.date < startedAt })
                .map({ epley($0.weightKg, $0.reps) }).max(),
              doneMax > prev + 0.1 else { return nil }
        return (doneMax, prev)
    }

    // MARK: - Acties

    private func addTemplate(_ routines: [(String, [String])]) {
        for (name, exercises) in routines {
            context.insert(Routine(name: name, exercises: exercises))
        }
    }

    private func startWorkout(with names: [String]) {
        startedAt = .now
        workout = names.map(draft(for:))
        WorkoutStatus.shared.startedAt = startedAt
        withAnimation(.snappy(duration: 0.3)) { active = true }
    }

    private func addExercise(_ name: String) {
        withAnimation(.snappy(duration: 0.25)) { workout.append(draft(for: name)) }
    }

    private func removeExercise(_ id: DraftExercise.ID) {
        if let ex = workout.first(where: { $0.id == id }) {
            for s in ex.sets { if let e = s.savedEntry, !e.isDeleted { context.delete(e) } }
        }
        withAnimation(.snappy(duration: 0.25)) { workout.removeAll { $0.id == id } }
    }

    private func saveExerciseNotes() {
        let notes = workout
            .map { ($0.name, $0.note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
        guard !notes.isEmpty else { return }
        let record = habits.first { cal.isDateInToday($0.date) } ?? {
            let h = DayHabits()
            context.insert(h)
            return h
        }()
        record.note = ([record.note] + notes).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func finishWorkout() {
        WorkoutStatus.shared.stopRest()
        saveExerciseNotes()
        WorkoutStatus.shared.startedAt = nil
        summary = WorkoutSummary(
            minutes: max(Int(Date.now.timeIntervalSince(startedAt) / 60), 1),
            volume: volume,
            sets: doneCount,
            prs: workout.compactMap { ex in prInfo(ex).map { (ex.name, $0.new, $0.old) } }
        )
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
        }
    }

    private func discardWorkout() {
        WorkoutStatus.shared.stopRest()
        WorkoutStatus.shared.startedAt = nil
        for s in workout.flatMap(\.sets) {
            if let e = s.savedEntry, !e.isDeleted { context.delete(e) }
        }
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
        }
    }

    private var doneCount: Int { workout.flatMap(\.sets).filter(\.done).count }
    private var volume: Int { Int(workout.flatMap(\.sets).filter(\.done).map { $0.kg * Double($0.reps) }.reduce(0, +)) }

    // MARK: - Body

    var body: some View {
        List {
            if active { activeSections } else { idleSections }
        }
        .navigationTitle("Training")
        .toolbar {
            if active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Afronden") { finishWorkout() }
                        .font(.headline)
                        .disabled(doneCount == 0)
                }
            }
        }
        .sensoryFeedback(.impact, trigger: doneCount)
        .sheet(item: $summary) { s in
            WorkoutSummarySheet(summary: s, name: profile.name)
        }
        .navigationDestination(item: $editingRoutine) { routine in
            RoutineEditorView(routine: routine)
        }
        .alert("Nieuwe oefening", isPresented: $showNewExercise) {
            TextField("bijv. Bench Press", text: $newExerciseName)
            Button("Toevoegen") {
                let name = newExerciseName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { addExercise(name) }
                newExerciseName = ""
            }
            Button("Annuleer", role: .cancel) { newExerciseName = "" }
        }
        .alert("Nieuwe routine", isPresented: $showNewRoutine) {
            TextField("bijv. Push, Pull of Upper A", text: $newRoutineName)
            Button("Aanmaken") {
                let name = newRoutineName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let routine = Routine(name: name)
                    context.insert(routine)
                    editingRoutine = routine
                }
                newRoutineName = ""
            }
            Button("Annuleer", role: .cancel) { newRoutineName = "" }
        }
        .confirmationDialog("Training annuleren?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwijder \(doneCount) sets", role: .destructive) { discardWorkout() }
            Button("Doorgaan met trainen", role: .cancel) {}
        }
    }

    // MARK: - Idle (Hevy Workout-tab)

    @ViewBuilder private var idleSections: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deze week").font(.headline)
                    Text("\(trainedThisWeek) van \(profile.trainingsPerWeek) trainingen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZStack {
                    Circle().stroke(Color(.tertiarySystemFill), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: min(1, Double(trainedThisWeek) / Double(max(profile.trainingsPerWeek, 1))))
                        .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if trainedThisWeek >= profile.trainingsPerWeek {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Text("\(trainedThisWeek)/\(profile.trainingsPerWeek)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .padding(.vertical, 2)
        }

        Section("Snel starten") {
            Button {
                startWorkout(with: [])
            } label: {
                Label("Lege training starten", systemImage: "plus")
            }
        }

        Section {
            if routines.isEmpty {
                Text("Nog geen routines. Begin met een template of maak er zelf een.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    addTemplate([
                        ("Push", ["Bench Press", "Incline Dumbbell Press", "Shoulder Press", "Triceps Pushdown", "Lateral Raises"]),
                        ("Pull", ["Deadlift", "Lat Pulldown", "Barbell Row", "Face Pulls", "Biceps Curl"]),
                        ("Legs", ["Squat", "Leg Press", "Romanian Deadlift", "Leg Curl", "Calf Raises"]),
                    ])
                } label: {
                    Label("Push / Pull / Legs", systemImage: "square.stack.3d.up")
                }
                Button {
                    addTemplate([
                        ("Upper", ["Bench Press", "Barbell Row", "Shoulder Press", "Lat Pulldown", "Biceps Curl"]),
                        ("Lower", ["Squat", "Romanian Deadlift", "Leg Press", "Leg Curl", "Calf Raises"]),
                    ])
                } label: {
                    Label("Upper / Lower", systemImage: "square.stack.3d.up")
                }
            }
            ForEach(routines) { routine in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.headline)
                            Text(routine.exercises.isEmpty ? "Nog geen oefeningen" : routine.exercises.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            Button("Wijzig routine", systemImage: "pencil") { editingRoutine = routine }
                            Button("Verwijder routine", systemImage: "trash", role: .destructive) {
                                context.delete(routine)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 24)
                        }
                    }
                    Button {
                        if routine.exercises.isEmpty {
                            editingRoutine = routine
                        } else {
                            startWorkout(with: routine.exercises)
                        }
                    } label: {
                        Text(routine.exercises.isEmpty ? "Oefeningen toevoegen" : "Start routine")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            }
        } header: {
            HStack {
                Text("Routines")
                Spacer()
                Button {
                    showNewRoutine = true
                } label: {
                    Image(systemName: "plus")
                }
                .font(.footnote.bold())
            }
        }

        if !pastDays.isEmpty {
            Section("Geschiedenis") {
                ForEach(pastDays, id: \.self) { day in
                    let daySets = sets(on: day)
                    let vol = Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                                .font(.headline)
                            Spacer()
                            Text("\(vol) kg")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        ForEach(byExercise(daySets), id: \.name) { group in
                            Text("\(group.name): " + group.sets.map { "\($0.weightKg.kgText)×\($0.reps)" }.joined(separator: "  "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    for i in offsets {
                        for s in sets(on: pastDays[i]) { context.delete(s) }
                    }
                }
            }
        }
    }

    // MARK: - Actieve training (Hevy Log Workout)

    @ViewBuilder private var activeSections: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duur").font(.caption2).foregroundStyle(.secondary)
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Volume").font(.caption2).foregroundStyle(.secondary)
                    Text("\(volume) kg")
                        .font(.subheadline.bold().monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: volume)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sets").font(.caption2).foregroundStyle(.secondary)
                    Text("\(doneCount)")
                        .font(.subheadline.bold().monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: doneCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        ForEach($workout) { $ex in
            Section {
                TextField("Notitie (bijv. voelde zwaar)", text: $ex.note, axis: .vertical)
                    .font(.footnote)
                    .listRowSeparator(.hidden)
                HStack(spacing: 12) {
                    Text("SET").frame(width: 24, alignment: .leading)
                    Text("VORIGE").frame(width: 64, alignment: .leading)
                    Text("KG").frame(width: 56)
                    Text("REPS").frame(width: 48)
                    Spacer()
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .listRowSeparator(.hidden)

                ForEach($ex.sets) { $set in
                    setRow($set, number: (ex.sets.firstIndex { $0.id == set.id } ?? 0) + 1, exercise: ex.name)
                }
                .onDelete { offsets in
                    for i in offsets {
                        if let e = ex.sets[i].savedEntry, !e.isDeleted { context.delete(e) }
                    }
                    ex.sets.remove(atOffsets: offsets)
                }

                Button {
                    let last = ex.sets.last ?? DraftSet(kg: 20, reps: 8)
                    let new = DraftSet(kg: last.kg, reps: last.reps, previous: nil)
                    withAnimation(.snappy(duration: 0.2)) { ex.sets.append(new) }
                    focusedSet = new.id
                } label: {
                    Label("Set toevoegen", systemImage: "plus")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            } header: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ex.name)
                            .font(.headline)
                            .foregroundStyle(.green)
                        if let pr = prInfo(ex) {
                            Text("🏆 Nieuw record — geschat 1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        } else if let tip = ex.tip {
                            Text(tip).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Oefening verwijderen", systemImage: "trash", role: .destructive) {
                            removeExercise(ex.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 20)
                    }
                }
                .textCase(nil) // ponytail: headers uppercasen anders ook het ⋯-menu
            }
        }

        Section {
            Menu {
                ForEach(recentExercises.filter { name in !workout.contains { $0.name == name } }, id: \.self) { name in
                    Button(name) { addExercise(name) }
                }
                Button("Nieuwe oefening…") { showNewExercise = true }
            } label: {
                Label("Oefening toevoegen", systemImage: "plus")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
        }

        Section {
            Button(role: .destructive) {
                if doneCount > 0 {
                    confirmDiscard = true
                } else {
                    discardWorkout()
                }
            } label: {
                Text("Training annuleren")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func setRow(_ set: Binding<DraftSet>, number: Int, exercise: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            Text(set.wrappedValue.previous ?? "—")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            TextField("kg", value: set.kg, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.subheadline.bold().monospacedDigit())
                .frame(width: 56)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .focused($focusedSet, equals: set.wrappedValue.id)
                .disabled(set.wrappedValue.done)
            TextField("reps", value: set.reps, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.subheadline.bold().monospacedDigit())
                .frame(width: 48)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .disabled(set.wrappedValue.done)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    set.wrappedValue.done.toggle()
                    if set.wrappedValue.done {
                        let e = SetEntry(exercise: exercise, weightKg: set.wrappedValue.kg, reps: set.wrappedValue.reps)
                        context.insert(e)
                        set.wrappedValue.savedEntry = e
                        WorkoutStatus.shared.startRest(seconds: restSeconds)
                    } else if let e = set.wrappedValue.savedEntry {
                        if !e.isDeleted { context.delete(e) }
                        set.wrappedValue.savedEntry = nil
                    }
                }
            } label: {
                Image(systemName: set.wrappedValue.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(set.wrappedValue.done ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(set.wrappedValue.done ? Color.green.opacity(0.12) : nil)
    }
}

// MARK: - Afrond-summary (zeldzaam moment → delight mag)

struct WorkoutSummarySheet: View {
    let summary: WorkoutSummary
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var bounced = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: bounced)
            Text("Sterk werk, \(name)! 💪")
                .font(.title2.bold())
            HStack {
                statTile("\(summary.minutes)", "minuten")
                statTile("\(summary.volume)", "kg volume")
                statTile("\(summary.sets)", "sets")
            }
            if !summary.prs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.prs, id: \.exercise) { pr in
                        Text("🏆 \(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                            .font(.subheadline.bold())
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                dismiss()
            } label: {
                Text("Klaar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium])
        .onAppear { bounced = true }
        .sensoryFeedback(.success, trigger: bounced)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RoutineEditorView: View {
    @Bindable var routine: Routine
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @State private var showNewExercise = false
    @State private var newExerciseName = ""

    private var recentExercises: [String] {
        var names: [String] = []
        for s in sets where !names.contains(s.exercise) {
            names.append(s.exercise)
        }
        return names.filter { !routine.exercises.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(routine.exercises, id: \.self) { name in
                    Label(name, systemImage: "line.3.horizontal")
                }
                .onMove { routine.exercises.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { routine.exercises.remove(atOffsets: $0) }
                Menu {
                    ForEach(recentExercises, id: \.self) { name in
                        Button(name) { routine.exercises.append(name) }
                    }
                    Button("Nieuwe oefening…") { showNewExercise = true }
                } label: {
                    Label("Oefening toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Oefeningen — sleep om de volgorde te bepalen")
            }
        }
        .tabBarClearance()
        .navigationTitle($routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .alert("Nieuwe oefening", isPresented: $showNewExercise) {
            TextField("bijv. Bench Press", text: $newExerciseName)
            Button("Toevoegen") {
                let name = newExerciseName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !routine.exercises.contains(name) {
                    routine.exercises.append(name)
                }
                newExerciseName = ""
            }
            Button("Annuleer", role: .cancel) { newExerciseName = "" }
        }
    }
}
