import SwiftUI
import SwiftData

struct DraftSet: Identifiable {
    let id = UUID()
    var kg: Double
    var reps: Int
    var done = false
    var previous: String?
    var savedEntry: SetEntry?
    var warmup = false
    var dropset = false
    var failure = false
}

struct DraftExercise: Identifiable {
    let id = UUID()
    var name: String
    var tip: String?
    var sets: [DraftSet]
    var note = ""
    /// Routine-oefening waar deze voor invalt (voor terugwisselen).
    var originalName: String?
    /// Superset-groep ("A"/"B"/…); zelfde groep = weinig rust ertussen.
    var superset: String?
    /// Rusttijd-override voor deze oefening (seconden); nil = globaal.
    var restSeconds: Int?
}

/// Lopende training op schijf, zodat een force-quit hem niet weggooit.
struct SavedWorkout: Codable, Equatable {
    struct SavedSet: Codable, Equatable {
        var kg: Double
        var reps: Int
        var done: Bool
        var previous: String?
        var warmup: Bool?
        var dropset: Bool?
        var failure: Bool?
    }
    struct SavedExercise: Codable, Equatable {
        var name: String
        var tip: String?
        var note: String
        var sets: [SavedSet]
        var originalName: String?
        var superset: String?
        var restSeconds: Int?
    }
    var startedAt: Date
    var exercises: [SavedExercise]
    var alternatives: [String: [String]]?
    /// Lopende rust bij het opslaan, zodat de timer na een force-quit klopt i.p.v. blijft hangen.
    var restEndsAt: Date?
}

struct WorkoutSummary: Identifiable {
    let id = UUID()
    let minutes: Int
    let volume: Int
    let sets: Int
    let prs: [(exercise: String, new: Double, old: Double)]
    var previousVolume: Int?
    var muscles: [String: Double] = [:]
}

struct TrainingView: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query(sort: \Routine.createdAt) private var routines: [Routine]
    @Query private var habits: [DayHabits]
    @Query private var exercises: [Exercise]
    @AppStorage("restSeconds") private var restSeconds = 120

    @State private var active = false
    @State private var workout: [DraftExercise] = []
    @State private var alternatives: [String: [String]] = [:]
    @State private var startedAt = Date.now
    @State private var summary: WorkoutSummary?
    @State private var editingRoutine: Routine?
    @State private var showExercisePicker = false
    @State private var showNewRoutine = false
    @State private var newRoutineName = ""
    @State private var confirmDiscard = false
    @State private var dayToDelete: Date?
    @State private var prToast: String?
    @FocusState private var focusedSet: UUID?
    private let workoutStatus = WorkoutStatus.shared

    private static let pplTemplate: [(String, [String])] = [
        ("Push", ["Bench Press", "Incline Dumbbell Press", "Shoulder Press", "Triceps Pushdown", "Lateral Raises"]),
        ("Pull", ["Deadlift", "Lat Pulldown", "Barbell Row", "Face Pulls", "Biceps Curl"]),
        ("Legs", ["Squat", "Leg Press", "Romanian Deadlift", "Leg Curl", "Calf Raises"]),
    ]
    private static let ulTemplate: [(String, [String])] = [
        ("Upper", ["Bench Press", "Barbell Row", "Shoulder Press", "Lat Pulldown", "Biceps Curl"]),
        ("Lower", ["Squat", "Romanian Deadlift", "Leg Press", "Leg Curl", "Calf Raises"]),
    ]

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

    private var weekDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: -6 + $0, to: cal.startOfDay(for: .now)) }
    }

    private let planDays: [(day: Int, label: String)] = [
        (2, "Maandag"), (3, "Dinsdag"), (4, "Woensdag"), (5, "Donderdag"),
        (6, "Vrijdag"), (7, "Zaterdag"), (1, "Zondag"),
    ]

    private var todayPlanned: Routine? {
        guard let name = profile.plannedRoutine(weekday: cal.component(.weekday, from: .now)) else { return nil }
        return routines.first { $0.name == name }
    }

    private func assignRoutine(_ name: String?, to weekday: Int) {
        if let name {
            profile.schedule[String(weekday)] = name
            if !profile.trainingDays.contains(weekday) { profile.trainingDays.append(weekday) }
        } else {
            profile.schedule[String(weekday)] = nil
            profile.trainingDays.removeAll { $0 == weekday }
        }
    }

    private func trained(on day: Date) -> Bool {
        sets.contains { cal.isDate($0.date, inSameDayAs: day) }
    }

    private func routineSubtitle(_ routine: Routine) -> String {
        guard !routine.exercises.isEmpty else { return "Nog geen oefeningen — tik om toe te voegen" }
        return "\(routine.exercises.count) oefeningen · " + routine.exercises.prefix(3).joined(separator: ", ")
    }

    private func lastDone(_ routine: Routine) -> Date? {
        sets.filter { routine.exercises.contains($0.exercise) }.map(\.date).max()
    }

    /// Dag met minstens één nieuw e1RM-record. ponytail: O(dagen × sets), prima op deze schaal.
    private func isPRDay(_ day: Date) -> Bool {
        for s in sets(on: day) {
            let before = sets.filter { $0.exercise == s.exercise && $0.date < cal.startOfDay(for: day) }
            let best = before.map { epley($0.weightKg, $0.reps) }.max() ?? 0
            if best > 0, epley(s.weightKg, s.reps) > best + 0.1 { return true }
        }
        return false
    }

    private var prCount: Int { workout.compactMap { prInfo($0) }.count }

    // MARK: - Doelgerichte voorstellen (dubbele progressie)

    private func draft(for name: String, target: [Int]? = nil) -> DraftExercise {
        let last = lastSession(for: name)
        let goalSets = target.map { max($0.first ?? 3, 1) }
        let goalReps = target.flatMap { $0.count > 1 ? $0[1] : nil }
        guard !last.isEmpty else {
            let n = goalSets ?? 3
            let reps = goalReps ?? 8
            return DraftExercise(name: name, tip: "Eerste keer — kies een gewicht dat je \(reps) reps aankan.",
                                 sets: (0..<n).map { _ in DraftSet(kg: 20, reps: reps) })
        }
        let top = last.map(\.weightKg).max() ?? 20
        let allEnough = last.allSatisfy { $0.reps >= (goalReps ?? 8) }
        let tip = allEnough
            ? "Vorige keer alles gehaald → vandaag \((top + 2.5).kgText) kg"
            : "Zelfde gewicht, probeer 1 rep meer per set."
        // Aantal sets uit het target (of het aantal van vorige keer), reps uit het target
        let count = goalSets ?? last.count
        return DraftExercise(name: name, tip: tip, sets: (0..<count).map { i in
            let prev = i < last.count ? last[i] : last.last
            return DraftSet(kg: allEnough ? top + 2.5 : top,
                            reps: goalReps ?? (allEnough ? 8 : min((prev?.reps ?? 8) + 1, 12)),
                            previous: prev.map { "\($0.weightKg.kgText)×\($0.reps)" })
        })
    }

    // PR op geschat 1RM (Epley): 8×60 telt dan ook als record t.o.v. 5×62,5
    /// Laatste notitie voor deze oefening, teruggevist uit de dagnotities
    /// (afronden schrijft ze als "Oefening: tekst").
    private func lastNote(for exercise: String) -> String? {
        let prefix = exercise + ": "
        let past = habits.filter { !cal.isDateInToday($0.date) }.sorted { $0.date > $1.date }
        for record in past {
            for line in record.note.components(separatedBy: "\n") where line.hasPrefix(prefix) {
                let note = String(line.dropFirst(prefix.count))
                if !note.isEmpty { return note }
            }
        }
        return nil
    }

    /// Effectieve rusttijd voor een oefening (per-oefening override of globaal).
    private func restFor(_ name: String) -> Int {
        workout.first { $0.name == name }?.restSeconds ?? restSeconds
    }

    /// Volledige vorige sessie van deze oefening, bijv. "40×8  40×8  37,5×7".
    private func lastSessionSummary(_ name: String) -> String? {
        let last = lastSession(for: name)
        guard !last.isEmpty else { return nil }
        return last.map { "\($0.weightKg.kgText)×\($0.reps)" }.joined(separator: "  ")
    }

    private func restLabel(_ seconds: Int) -> String {
        seconds <= 0 ? "uit" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func setRest(_ id: UUID, _ seconds: Int?) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        workout[i].restSeconds = seconds
    }

    private func moveExercise(_ id: UUID, by offset: Int) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard workout.indices.contains(j) else { return }
        withAnimation(.snappy(duration: 0.25)) { workout.swapAt(i, j) }
    }

    /// Nieuw geschat 1RM-record t.o.v. je historie én eerdere sets deze sessie?
    private func isNewPR(exercise name: String, kg: Double, reps: Int) -> Bool {
        let now = epley(kg, reps)
        let historical = sets.filter { $0.exercise == name && $0.date < startedAt }
            .map { epley($0.weightKg, $0.reps) }.max() ?? 0
        let sessionBest = workout.first { $0.name == name }?.sets
            .filter { $0.done && !$0.warmup }.map { epley($0.kg, $0.reps) }.max() ?? 0
        return now > max(historical, sessionBest) + 0.1 && historical > 0
    }

    private func prInfo(_ ex: DraftExercise) -> (new: Double, old: Double)? {
        guard let doneMax = ex.sets.filter { $0.done && !$0.warmup }.map({ epley($0.kg, $0.reps) }).max() else { return nil }
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

    private var draftSnapshot: SavedWorkout? {
        guard active else { return nil }
        return SavedWorkout(startedAt: startedAt, exercises: workout.map { ex in
            .init(name: ex.name, tip: ex.tip, note: ex.note,
                  sets: ex.sets.map { .init(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, warmup: $0.warmup, dropset: $0.dropset, failure: $0.failure) },
                  originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }, alternatives: alternatives.isEmpty ? nil : alternatives,
           restEndsAt: workoutStatus.restEndsAt)
    }

    /// Na een force-quit: training terugzetten en de Live Activity weer adopteren.
    private func restoreDraft() {
        guard !active,
              let data = UserDefaults.standard.data(forKey: "activeWorkout"),
              let saved = try? JSONDecoder().decode(SavedWorkout.self, from: data) else { return }
        startedAt = saved.startedAt
        workout = saved.exercises.map { ex in
            DraftExercise(name: ex.name, tip: ex.tip,
                          sets: ex.sets.map { DraftSet(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, warmup: $0.warmup ?? false, dropset: $0.dropset ?? false, failure: $0.failure ?? false) },
                          note: ex.note, originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }
        alternatives = saved.alternatives ?? [:]
        active = true
        if workoutStatus.startedAt == nil {
            workoutStatus.resumeWorkout(at: saved.startedAt)
            // Rust herstellen als hij nog loopt, anders een stale timer op het lockscreen wissen.
            if let end = saved.restEndsAt, end > .now {
                workoutStatus.startRest(until: end)
            } else {
                workoutStatus.stopRest()
            }
        }
    }

    /// Vervangers voor deze oefening: de alternatieven uit de routine + de originele om terug te wisselen.
    private func swapOptions(_ ex: DraftExercise) -> [String] {
        let original = ex.originalName ?? ex.name
        let alts = alternatives[original] ?? []
        guard !alts.isEmpty else { return [] }
        return ([original] + alts).filter { $0 != ex.name }
    }

    /// Warming-up-sets vóór de werksets: ramp naar het eerste werkgewicht.
    private func addWarmup(_ id: UUID) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        let work = workout[i].sets.first { !$0.warmup }
        let topKg = work?.kg ?? 20
        let reps = work?.reps ?? 8
        let ramp: [(Double, Int)] = [(0.4, min(reps + 4, 10)), (0.6, max(reps - 2, 3)), (0.8, max(reps - 4, 2))]
        let warmups = ramp.map { pct, r in
            DraftSet(kg: (topKg * pct / 2.5).rounded() * 2.5, reps: r, warmup: true)
        }
        withAnimation(.snappy(duration: 0.25)) { workout[i].sets.insert(contentsOf: warmups, at: 0) }
    }

    private func removeWarmup(_ id: UUID) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.25)) { workout[i].sets.removeAll(where: \.warmup) }
    }

    /// Na een superset-set (niet de laatste van de groep in de volgorde) sla je de rust over.
    private func shouldRest(after name: String) -> Bool {
        guard let i = workout.firstIndex(where: { $0.name == name }),
              let group = workout[i].superset else { return true }
        let next = workout.indices.contains(i + 1) ? workout[i + 1].superset : nil
        return next != group
    }

    private func swapExercise(_ id: UUID, to newName: String) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        let original = workout[i].originalName ?? workout[i].name
        var replacement = draft(for: newName)
        replacement.originalName = original
        withAnimation(.snappy(duration: 0.25)) { workout[i] = replacement }
    }

    private func startWorkout(with names: [String], alternatives alts: [String: [String]] = [:],
                             targets: [String: [Int]] = [:], supersets: [String: String] = [:],
                             restByExercise: [String: Int] = [:]) {
        startedAt = .now
        workout = names.map { name in
            var d = draft(for: name, target: targets[name])
            d.superset = supersets[name]
            d.restSeconds = restByExercise[name]
            return d
        }
        alternatives = alts
        WorkoutStatus.shared.startWorkout(at: startedAt)
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

    /// Spiergroep-intensiteit van de zojuist afgeronde training (0…1, genormaliseerd op volume).
    private func sessionMuscles() -> [String: Double] {
        let muscleOf = Dictionary(exercises.map { ($0.name, $0.muscle) }, uniquingKeysWith: { a, _ in a })
        var totals: [String: Double] = [:]
        for ex in workout {
            let m = muscleOf[ex.originalName ?? ex.name] ?? muscleOf[ex.name] ?? "Overig"
            let vol = ex.sets.filter { $0.done && !$0.warmup }.map { $0.kg * Double($0.reps) }.reduce(0, +)
            if vol > 0 { totals[m, default: 0] += vol }
        }
        guard let maxV = totals.values.max(), maxV > 0 else { return [:] }
        return totals.mapValues { $0 / maxV }
    }

    private func finishWorkout() {
        saveExerciseNotes()
        WorkoutStatus.shared.endWorkout()
        let previousDay = pastDays.first { !cal.isDateInToday($0) }
        let previousVolume = previousDay.map { day in
            Int(sets(on: day).map { $0.weightKg * Double($0.reps) }.reduce(0, +))
        }
        summary = WorkoutSummary(
            minutes: max(Int(Date.now.timeIntervalSince(startedAt) / 60), 1),
            volume: volume,
            sets: doneCount,
            prs: workout.compactMap { ex in prInfo(ex).map { (ex.name, $0.new, $0.old) } },
            previousVolume: previousVolume,
            muscles: sessionMuscles()
        )
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
        }
    }

    private func discardWorkout() {
        WorkoutStatus.shared.endWorkout()
        for s in workout.flatMap(\.sets) {
            if let e = s.savedEntry, !e.isDeleted { context.delete(e) }
        }
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
        }
    }

    private var doneCount: Int { workout.flatMap(\.sets).filter { $0.done && !$0.warmup }.count }
    private var volume: Int { Int(workout.flatMap(\.sets).filter { $0.done && !$0.warmup }.map { $0.kg * Double($0.reps) }.reduce(0, +)) }

    // MARK: - Body

    var body: some View {
        List {
            if active { activeSections } else { idleSections }
        }
        .navigationTitle("Training")
        .toolbar {
            if active {
                ToolbarItem(placement: .principal) {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Afronden") { finishWorkout() }
                        .font(.headline)
                        .disabled(doneCount == 0)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if workoutStatus.restEndsAt != nil {
                Color.clear.frame(height: 68) // rust-balk overlapt anders de onderste rijen
            }
        }
        .task { restoreDraft() }
        .onChange(of: draftSnapshot) { _, snap in
            if let snap, let data = try? JSONEncoder().encode(snap) {
                UserDefaults.standard.set(data, forKey: "activeWorkout")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeWorkout")
            }
        }
        .sensoryFeedback(.impact, trigger: doneCount)
        .sensoryFeedback(.success, trigger: prCount) { old, new in new > old }
        .overlay(alignment: .top) {
            if let prToast {
                Text(prToast)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.green, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(.snappy) { self.prToast = nil }
                    }
            }
        }
        .animation(.snappy(duration: 0.3), value: prToast)
        .sensoryFeedback(.success, trigger: prToast) { _, new in new != nil }
        .confirmationDialog("Trainingsdag verwijderen?",
                            isPresented: Binding(get: { dayToDelete != nil },
                                                 set: { if !$0 { dayToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \(dayToDelete.map { sets(on: $0).count } ?? 0) sets", role: .destructive) {
                if let day = dayToDelete {
                    for s in sets(on: day) { context.delete(s) }
                }
                dayToDelete = nil
            }
            Button("Annuleer", role: .cancel) { dayToDelete = nil }
        }
        .sheet(item: $summary) { s in
            WorkoutSummarySheet(summary: s, name: profile.name)
        }
        .navigationDestination(item: $editingRoutine) { routine in
            RoutineEditorView(routine: routine)
        }
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerSheet(exclude: Set(workout.map(\.name))) { name in
                addExercise(name)
            }
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
    private var thisWeekSection: some View {
        Section {
            VStack(spacing: 10) {
                HStack {
                    Text("Deze week").font(.headline)
                    Spacer()
                    Text("\(trainedThisWeek) van \(profile.trainingsPerWeek) trainingen")
                        .font(.footnote)
                        .foregroundStyle(trainedThisWeek >= profile.trainingsPerWeek ? .green : .secondary)
                }
                HStack(spacing: 8) {
                    ForEach(weekDays, id: \.self) { day in
                        weekDot(day)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func weekDot(_ day: Date) -> some View {
        let did = trained(on: day)
        return VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .foregroundStyle(cal.isDateInToday(day) ? .primary : .secondary)
            ZStack {
                Circle()
                    .fill(did ? Color.green : Color(.tertiarySystemFill))
                    .frame(width: 30, height: 30)
                if did {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                } else if cal.isDateInToday(day) {
                    Circle().strokeBorder(.green, lineWidth: 2).frame(width: 30, height: 30)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var planningSection: some View {
        if !routines.isEmpty {
            Section {
                ForEach(planDays, id: \.day) { entry in
                    planningRow(entry.day, entry.label)
                }
            } header: {
                Text("Weekplanning")
            } footer: {
                Text("Koppel een routine aan een dag. Op die dag zie je bovenaan \u{201C}Vandaag gepland\u{201D} en tellen meldingen mee.")
            }
        }
    }

    private func planningRow(_ weekday: Int, _ label: String) -> some View {
        let assigned = profile.plannedRoutine(weekday: weekday)
        return Menu {
            Button("Rustdag") { assignRoutine(nil, to: weekday) }
            Divider()
            ForEach(routines) { routine in
                Button {
                    assignRoutine(routine.name, to: weekday)
                } label: {
                    if assigned == routine.name {
                        Label(routine.name, systemImage: "checkmark")
                    } else {
                        Text(routine.name)
                    }
                }
            }
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text(assigned ?? "Rustdag")
                    .foregroundStyle(assigned == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func plannedCard(_ planned: Routine) -> some View {
        Button {
            startWorkout(with: planned.exercises, alternatives: planned.alternatives, targets: planned.targets, supersets: planned.supersets, restByExercise: planned.restByExercise)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vandaag gepland").font(.caption).foregroundStyle(.secondary)
                    Text(planned.name).font(.headline).foregroundStyle(.primary)
                }
                Spacer()
                Text("Start")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green, in: Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PressableStyle())
    }


    @ViewBuilder private var idleSections: some View {
        if let planned = todayPlanned, !trained(on: cal.startOfDay(for: .now)) {
            Section { plannedCard(planned) }
        }

        thisWeekSection

        planningSection

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
                    addTemplate(Self.pplTemplate)
                } label: {
                    Label("Push / Pull / Legs", systemImage: "square.stack.3d.up")
                }
                Button {
                    addTemplate(Self.ulTemplate)
                } label: {
                    Label("Upper / Lower", systemImage: "square.stack.3d.up")
                }
            }
            ForEach(routines) { routine in
                Button {
                    if routine.exercises.isEmpty {
                        editingRoutine = routine
                    } else {
                        startWorkout(with: routine.exercises, alternatives: routine.alternatives, targets: routine.targets, supersets: routine.supersets, restByExercise: routine.restByExercise)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: routine.exercises.isEmpty ? "square.and.pencil" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.headline).foregroundStyle(.primary)
                            Text(routineSubtitle(routine))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let last = lastDone(routine) {
                                Text("Laatst: \(last.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Wijzig routine", systemImage: "pencil") { editingRoutine = routine }
                            Button("Verwijder routine", systemImage: "trash", role: .destructive) {
                                // Ruim de weekplanning op zodat een dode naam niet in agenda/meldingen blijft spoken
                                for (weekday, name) in profile.schedule where name == routine.name {
                                    profile.schedule[weekday] = nil
                                    if let day = Int(weekday) { profile.trainingDays.removeAll { $0 == day } }
                                }
                                context.delete(routine)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(.rect)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(PressableStyle())
            }
        } header: {
            HStack {
                Text("Routines")
                Spacer()
                Menu {
                    Button("Nieuwe routine…", systemImage: "plus") { showNewRoutine = true }
                    Divider()
                    Button("Template: Push / Pull / Legs") { addTemplate(Self.pplTemplate) }
                    Button("Template: Upper / Lower") { addTemplate(Self.ulTemplate) }
                } label: {
                    Image(systemName: "plus")
                }
                .font(.footnote.bold())
            }
        }

        Section("Geschiedenis") {
            if pastDays.isEmpty {
                Text("Je eerste training verschijnt hier — met volume, oefeningen en records.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(pastDays, id: \.self) { day in
                let daySets = sets(on: day)
                let vol = Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
                NavigationLink {
                    SessionDetailView(day: day)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                                .font(.headline)
                            if isPRDay(day) {
                                Text("🏆").font(.caption)
                            }
                            Spacer()
                            Text("\(vol) kg")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(byExercise(daySets), id: \.name) { group in
                            Text("\(group.name): " + group.sets.map { "\($0.weightKg.kgText)×\($0.reps)" }.joined(separator: "  "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                if let i = offsets.first { dayToDelete = pastDays[i] }
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
            if doneCount == 0 {
                Text("Vink een set af om te kunnen afronden.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        ForEach($workout) { $ex in
            Section {
                if let previousNote = lastNote(for: ex.name) {
                    Label("Vorige keer: \u{201C}\(previousNote)\u{201D}", systemImage: "text.quote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
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
                    let idx = ex.sets.firstIndex { $0.id == set.id } ?? 0
                    setRow($set, number: ex.sets[...idx].filter { !$0.warmup }.count, exercise: ex.name)
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
                        HStack(spacing: 6) {
                            if let group = ex.superset {
                                Text("Superset \(group)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                            Text(ex.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        if let pr = prInfo(ex) {
                            Text("🏆 Nieuw record — geschat 1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        } else if let tip = ex.tip {
                            Text(tip).font(.caption).foregroundStyle(.secondary)
                        }
                        if let prev = lastSessionSummary(ex.name) {
                            Label(prev, systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Menu {
                        let options = swapOptions(ex)
                        if !options.isEmpty {
                            if ex.sets.contains(where: \.done) {
                                Text("Vervangen kan alleen vóór je eerste set")
                            } else {
                                Section("Vervang door") {
                                    ForEach(options, id: \.self) { alt in
                                        Button(alt, systemImage: "arrow.triangle.2.circlepath") {
                                            swapExercise(ex.id, to: alt)
                                        }
                                    }
                                }
                            }
                        }
                        if ex.sets.contains(where: \.warmup) {
                            Button("Warming-up weghalen", systemImage: "flame") { removeWarmup(ex.id) }
                        } else {
                            Button("Warming-up toevoegen", systemImage: "flame") { addWarmup(ex.id) }
                        }
                        Menu("Rust: \(restLabel(ex.restSeconds ?? restSeconds))", systemImage: "timer") {
                            Button("Standaard (\(restLabel(restSeconds)))") { setRest(ex.id, nil) }
                            ForEach([60, 90, 120, 180], id: \.self) { sec in
                                Button(restLabel(sec)) { setRest(ex.id, sec) }
                            }
                        }
                        Divider()
                        Button("Verplaats omhoog", systemImage: "arrow.up") { moveExercise(ex.id, by: -1) }
                        Button("Verplaats omlaag", systemImage: "arrow.down") { moveExercise(ex.id, by: 1) }
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
            Button {
                showExercisePicker = true
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

    /// Voedt de Live Activity: oefening, set-voortgang en een PR-tip op basis van je vorige sessie.
    private func updateActivity(exercise name: String, currentKg: Double) {
        guard let ex = workout.first(where: { $0.name == name }) else { return }
        WorkoutStatus.shared.updateContext(exercise: name,
                                           setsDone: ex.sets.filter(\.done).count,
                                           setsTotal: ex.sets.count,
                                           tip: activityTip(for: name, currentKg: currentKg))
    }

    private func activityTip(for name: String, currentKg: Double) -> String? {
        let last = lastSession(for: name)
        guard let best = last.max(by: { epley($0.weightKg, $0.reps) < epley($1.weightKg, $1.reps) }) else { return nil }
        let prevText = "Vorige keer: \(best.weightKg.kgText) kg × \(best.reps)"
        let prevE1RM = epley(best.weightKg, best.reps)
        if currentKg > best.weightKg {
            // Epley omgekeerd: hoeveel reps op dit gewicht nodig zijn om je oude 1RM te kloppen
            let reps = max(Int(30 * (prevE1RM / currentKg - 1)) + 1, 1)
            return "\(prevText) — met \(currentKg.kgText) kg is \(reps)+ reps een PR"
        }
        return prevText
    }

    private func setLabel(_ set: DraftSet, number: Int) -> String {
        if set.warmup { return "W" }
        var s = "\(number)"
        if set.dropset { s += " D" }
        if set.failure { s += " F" }
        return s
    }

    private func setRow(_ set: Binding<DraftSet>, number: Int, exercise: String) -> some View {
        HStack(spacing: 12) {
            Menu {
                Button { set.wrappedValue.warmup = false } label: {
                    Label("Normale set", systemImage: set.wrappedValue.warmup ? "circle" : "checkmark")
                }
                Button { set.wrappedValue.warmup = true } label: {
                    Label("Warming-up", systemImage: set.wrappedValue.warmup ? "checkmark" : "flame")
                }
                Divider()
                Button(set.wrappedValue.dropset ? "Geen drop-set" : "Drop-set", systemImage: "arrow.down.right") {
                    set.wrappedValue.dropset.toggle()
                }
                Button(set.wrappedValue.failure ? "Niet naar falen" : "Naar falen", systemImage: "flame") {
                    set.wrappedValue.failure.toggle()
                }
            } label: {
                Text(setLabel(set.wrappedValue, number: number))
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(set.wrappedValue.warmup || set.wrappedValue.dropset || set.wrappedValue.failure
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 34, alignment: .leading)
                    .opacity(set.wrappedValue.done ? 0.55 : 1)
                    .contentShape(Rectangle())
            }
            Text(set.wrappedValue.previous ?? "—")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
                .opacity(set.wrappedValue.done ? 0.55 : 1)
            NumericField(value: set.kg, decimal: true, placeholder: "kg",
                         focus: $focusedSet, id: set.wrappedValue.id,
                         disabled: set.wrappedValue.done)
                .frame(width: 56)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .opacity(set.wrappedValue.done ? 0.55 : 1)
            NumericField(value: Binding(get: { Double(set.wrappedValue.reps) },
                                        set: { set.wrappedValue.reps = Int(min($0.rounded(), 9999)) }),
                         decimal: false, placeholder: "reps",
                         focus: $focusedSet, id: nil,
                         disabled: set.wrappedValue.done)
                .frame(width: 48)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .opacity(set.wrappedValue.done ? 0.55 : 1)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    set.wrappedValue.done.toggle()
                    if set.wrappedValue.done {
                        if !set.wrappedValue.warmup {
                            let e = SetEntry(exercise: exercise, weightKg: set.wrappedValue.kg, reps: set.wrappedValue.reps,
                                             dropset: set.wrappedValue.dropset, failure: set.wrappedValue.failure)
                            context.insert(e)
                            set.wrappedValue.savedEntry = e
                        }
                        // Warming-up en tussen-superset-sets: geen (of minimale) rust
                        if !set.wrappedValue.warmup, shouldRest(after: exercise) {
                            WorkoutStatus.shared.startRest(seconds: restFor(exercise))
                        }
                        if !set.wrappedValue.warmup,
                           isNewPR(exercise: exercise, kg: set.wrappedValue.kg, reps: set.wrappedValue.reps) {
                            prToast = "🏆 Record — \(exercise)!"
                        }
                    } else {
                        // Na een herstelde training is savedEntry weg — zoek 'm terug
                        let e = set.wrappedValue.savedEntry ?? sets.first {
                            $0.exercise == exercise && $0.date >= startedAt
                                && $0.weightKg == set.wrappedValue.kg && $0.reps == set.wrappedValue.reps
                        }
                        if let e, !e.isDeleted { context.delete(e) }
                        set.wrappedValue.savedEntry = nil
                    }
                    updateActivity(exercise: exercise, currentKg: set.wrappedValue.kg)
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
        ScrollView {
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
                if let prev = summary.previousVolume, prev > 0 {
                    let delta = summary.volume - prev
                    Text("\(delta >= 0 ? "+" : "")\(delta) kg volume t.o.v. je vorige training")
                        .font(.footnote)
                        .foregroundStyle(delta >= 0 ? .green : .secondary)
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
                if !summary.muscles.isEmpty {
                    VStack(spacing: 6) {
                        Text("Vandaag geraakt").font(.caption).foregroundStyle(.secondary)
                        BodyMapView(values: summary.muscles, figureHeight: 180)
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                dismiss()
            } label: {
                Text("Klaar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

/// Overzicht van één gedane training: duur, volume, verbeteringen — en bewerkbaar
/// (kg/reps aanpassen, set of oefening verwijderen).
struct SessionDetailView: View {
    let day: Date
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @FocusState private var focused: UUID?

    private var cal: Calendar { .current }
    private var daySets: [SetEntry] {
        allSets.filter { cal.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
    }

    private var byExercise: [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets where !names.contains(s.exercise) { names.append(s.exercise) }
        return names.map { n in (n, daySets.filter { $0.exercise == n }) }
    }

    private var volume: Int { Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +)) }

    private var durationText: String {
        guard let first = daySets.first?.date, let last = daySets.last?.date, last > first else { return "—" }
        let m = max(Int(last.timeIntervalSince(first) / 60), 1)
        return m >= 60 ? "\(m / 60)u \(m % 60)m" : "\(m) min"
    }

    /// Vorige trainingsdag die minstens één oefening deelt — basis voor de vergelijking.
    private var previousDay: Date? {
        let names = Set(daySets.map(\.exercise))
        let start = cal.startOfDay(for: day)
        return allSets.filter { $0.date < start && names.contains($0.exercise) }
            .map { cal.startOfDay(for: $0.date) }.max()
    }

    private var volumeDelta: Int? {
        guard let prev = previousDay else { return nil }
        let pv = Int(allSets.filter { cal.isDate($0.date, inSameDayAs: prev) }
            .map { $0.weightKg * Double($0.reps) }.reduce(0, +))
        return pv > 0 ? volume - pv : nil
    }

    /// Oefeningen met een nieuw e1RM-record deze dag t.o.v. alles ervoor.
    private var prs: [(exercise: String, new: Double, old: Double)] {
        let start = cal.startOfDay(for: day)
        return byExercise.compactMap { group in
            let best = group.sets.map { epley($0.weightKg, $0.reps) }.max() ?? 0
            let before = allSets.filter { $0.exercise == group.name && $0.date < start }
                .map { epley($0.weightKg, $0.reps) }.max() ?? 0
            return best > before + 0.1 && before > 0 ? (group.name, best, before) : nil
        }
    }

    private func kg(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { set.weightKg }, set: { set.weightKg = $0 })
    }
    private func reps(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { Double(set.reps) }, set: { set.reps = Int(min($0.rounded(), 9999)) })
    }

    var body: some View {
        List {
            Section {
                HStack {
                    statTile(durationText, "duur")
                    statTile("\(volume)", "kg volume")
                    statTile("\(daySets.count)", "sets")
                }
                if let d = volumeDelta {
                    Text("\(d >= 0 ? "+" : "")\(d) kg volume t.o.v. je vorige training")
                        .font(.footnote)
                        .foregroundStyle(d >= 0 ? .green : .secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if !prs.isEmpty {
                Section("Records") {
                    ForEach(prs, id: \.exercise) { pr in
                        Text("🏆 \(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                            .font(.subheadline.bold())
                    }
                }
            }

            ForEach(byExercise, id: \.name) { group in
                Section(group.name) {
                    ForEach(Array(group.sets.enumerated()), id: \.element.persistentModelID) { i, set in
                        HStack(spacing: 12) {
                            Text("\(i + 1)\(set.dropset ? " D" : "")\(set.failure ? " F" : "")")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(set.dropset || set.failure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .frame(width: 40, alignment: .leading)
                            NumericField(value: kg(set), decimal: true, placeholder: "kg",
                                         focus: $focused, id: nil, disabled: false)
                                .frame(width: 64)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            Text("kg").font(.footnote).foregroundStyle(.secondary)
                            NumericField(value: reps(set), decimal: false, placeholder: "reps",
                                         focus: $focused, id: nil, disabled: false)
                                .frame(width: 52)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            Text("reps").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(group.sets[i]) }
                    }
                    Button {
                        if let last = group.sets.last {
                            context.insert(SetEntry(date: last.date.addingTimeInterval(1),
                                                    exercise: group.name, weightKg: last.weightKg, reps: last.reps))
                        }
                    } label: {
                        Label("Set toevoegen", systemImage: "plus")
                    }
                }
            }
        }
        .tabBarClearance()
        .navigationTitle(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
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
    @State private var showPicker = false

    private func subtitle(for name: String) -> String {
        var parts: [String] = []
        if let t = routine.targets[name], t.count > 1 {
            parts.append("\(t[0]) × \(t[1])")
        }
        let alts = routine.alternatives[name] ?? []
        if !alts.isEmpty { parts.append("Alt: \(alts.joined(separator: ", "))") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        List {
            Section {
                ForEach(routine.exercises, id: \.self) { name in
                    NavigationLink {
                        RoutineExerciseEditor(routine: routine, exercise: name)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).foregroundStyle(.primary)
                                let sub = subtitle(for: name)
                                if !sub.isEmpty {
                                    Text(sub)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .onMove { routine.exercises.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for i in offsets {
                        routine.alternatives[routine.exercises[i]] = nil
                        routine.targets[routine.exercises[i]] = nil
                    }
                    routine.exercises.remove(atOffsets: offsets)
                }
                Button {
                    showPicker = true
                } label: {
                    Label("Oefening toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Oefeningen — sleep om de volgorde te bepalen")
            } footer: {
                Text("Tik op een oefening voor sets × reps en alternatieven. Tijdens de training wissel je via het ⋯-menu als een toestel bezet is.")
            }
        }
        .tabBarClearance()
        .navigationTitle($routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $showPicker) {
            ExercisePickerSheet(exclude: Set(routine.exercises)) { name in
                if !routine.exercises.contains(name) { routine.exercises.append(name) }
            }
        }
    }
}

/// Per oefening: doel (sets × reps) en alternatieven.
struct RoutineExerciseEditor: View {
    @Bindable var routine: Routine
    let exercise: String
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @State private var showAltPicker = false

    private var target: [Int] { routine.targets[exercise] ?? [3, 8] }
    private func setTarget(sets s: Int, reps r: Int) { routine.targets[exercise] = [s, r] }

    var body: some View {
        List {
            Section {
                Stepper("Sets: \(target[0])", value: Binding(
                    get: { target[0] },
                    set: { setTarget(sets: $0, reps: target[1]) }
                ), in: 1...10)
                Stepper("Reps: \(target[1])", value: Binding(
                    get: { target[1] },
                    set: { setTarget(sets: target[0], reps: $0) }
                ), in: 1...30)
            } header: {
                Text("Doel")
            } footer: {
                Text("Bij het starten van de routine krijg je \(target[0]) sets van \(target[1]) reps voorgezet.")
            }

            Section {
                Picker("Superset", selection: Binding(
                    get: { routine.supersets[exercise] ?? "" },
                    set: { routine.supersets[exercise] = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Geen").tag("")
                    ForEach(["A", "B", "C", "D"], id: \.self) { Text("Groep \($0)").tag($0) }
                }
            } footer: {
                Text("Oefeningen in dezelfde groep doe je achter elkaar met weinig rust ertussen; de rusttimer start pas na de laatste van de groep.")
            }

            Section {
                Picker("Rusttijd", selection: Binding(
                    get: { routine.restByExercise[exercise] ?? 0 },
                    set: { routine.restByExercise[exercise] = $0 == 0 ? nil : $0 }
                )) {
                    Text("Standaard").tag(0)
                    Text("1:00").tag(60)
                    Text("1:30").tag(90)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                }
            } footer: {
                Text("Rust ná een set van deze oefening. \u{201C}Standaard\u{201D} volgt de instelling in je profiel.")
            }

            Section {
                ForEach(routine.alternatives[exercise] ?? [], id: \.self) { alt in
                    Text(alt)
                }
                .onDelete { offsets in
                    var alts = routine.alternatives[exercise] ?? []
                    alts.remove(atOffsets: offsets)
                    routine.alternatives[exercise] = alts.isEmpty ? nil : alts
                }
                Button {
                    showAltPicker = true
                } label: {
                    Label("Alternatief toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Alternatieven")
            } footer: {
                Text("Vervangers als dit toestel bezet of stuk is — kies je tijdens de training via het ⋯-menu.")
            }
        }
        .navigationTitle(exercise)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAltPicker) {
            ExercisePickerSheet(exclude: Set([exercise] + (routine.alternatives[exercise] ?? []))) { name in
                routine.alternatives[exercise, default: []].append(name)
            }
        }
    }
}

// MARK: - Numeriek invoerveld met cursor altijd achteraan

/// UITextField-wrapper: reformat gebeurt niet tijdens het typen (geen cursor-sprong)
/// en bij focus staat de cursor achteraan. Ondersteunt de autofocus-op-volgende-set.
struct NumericField: UIViewRepresentable {
    @Binding var value: Double
    var decimal: Bool
    var placeholder: String
    var focus: FocusState<UUID?>.Binding
    var id: UUID?
    var disabled: Bool

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.keyboardType = decimal ? .decimalPad : .numberPad
        tf.textAlignment = .center
        tf.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        tf.adjustsFontSizeToFitWidth = true
        tf.minimumFontSize = 11
        tf.placeholder = placeholder
        tf.text = context.coordinator.string(from: value)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self
        tf.isEnabled = !disabled
        // Alleen overschrijven als de gebruiker hier niet typt → geen cursor-sprong
        if !tf.isFirstResponder {
            let formatted = context.coordinator.string(from: value)
            if tf.text != formatted { tf.text = formatted }
        }
        if let id, focus.wrappedValue == id, !tf.isFirstResponder, !disabled {
            DispatchQueue.main.async { tf.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumericField
        init(_ parent: NumericField) { self.parent = parent }

        func string(from value: Double) -> String {
            if parent.decimal {
                return value == value.rounded()
                    ? String(Int(value))
                    : String(value).replacingOccurrences(of: ".", with: ",")
            }
            return String(Int(value))
        }

        @objc func editingChanged(_ tf: UITextField) {
            let raw = (tf.text ?? "").replacingOccurrences(of: ",", with: ".")
            if let v = Double(raw) { parent.value = v }
            else if raw.isEmpty { parent.value = 0 }
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            if let id = parent.id { parent.focus.wrappedValue = id }
            let end = tf.endOfDocument
            tf.selectedTextRange = tf.textRange(from: end, to: end) // cursor achteraan
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            if let id = parent.id, parent.focus.wrappedValue == id { parent.focus.wrappedValue = nil }
            tf.text = string(from: parent.value)
        }
    }
}
