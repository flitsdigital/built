import SwiftUI
import SwiftData

/// `sheet(item:)` en `navigationDestination(item:)` willen iets identificeerbaars, en een
/// oefeningnaam is maar een String.
struct ExerciseName: Identifiable, Hashable {
    let name: String
    var id: String { name }
    init(_ name: String) { self.name = name }
}

struct TrainingView: View {
    let profile: Profile
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query(sort: \Routine.createdAt) private var routines: [Routine]
    @Query private var habits: [DayHabits]
    @Query private var exercises: [Exercise]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @AppStorage("restSeconds") private var restSeconds = 120

    /// Huidig lichaamsgewicht voor het meetellen van bodyweight-oefeningen in het volume.
    private var bodyWeight: Double { weights.last?.kg ?? profile.startWeight }

    @State private var active = false
    @State private var workout: [DraftExercise] = []
    @State private var alternatives: [String: [String]] = [:]
    @State private var workoutNote = ""
    @State private var workoutName = ""
    @State private var showStopwatch = false
    /// Wanneer de training telt. Standaard nu; terugzetten verhuist de sets en het
    /// trainingsvinkje mee naar die dag.
    @State private var workoutDate = Date.now
    @State private var startedAt = Date.now
    @State private var summary: WorkoutSummary?
    @State private var editingRoutine: Routine?
    @State private var showExercisePicker = false
    @State private var showNewRoutine = false
    @State private var newRoutineName = ""
    @State private var confirmDiscard = false
    @State private var sessionToDelete: WorkoutSession?
    @State private var exerciseToRemove: DraftExercise.ID?
    @State private var prToast: String?
    /// Welke oefening je voortgang van bekijkt. Een sheet, geen push: je kijkt er tussen
    /// twee sets door naar en veegt 'm weg — een terugknop is dan omslachtig.
    @State private var detailExercise: ExerciseName?
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

    // MARK: - Historie-index
    //
    // Elke helper hieronder filterde eerder de volledige sets-tabel, en dat per oefening
    // én per historie-dag, bij élke render. Nu wordt er één keer per render gegroepeerd.

    /// Sets per oefening en per dag, plus de oefening-catalogus als opzoektabel.
    /// `isBodyweight` en vrienden komen van `ExerciseTypes`.
    struct HistoryIndex: ExerciseTypes {
        var byExercise: [String: [SetEntry]] = [:]
        var byDay: [Int: [SetEntry]] = [:]
        /// Beste geschat 1RM per oefening vóór een gegeven dag — voor de PR-badges.
        var typeOf: [String: String] = [:]
        var muscleOf: [String: String] = [:]

        func type(of name: String) -> String? { typeOf[name] }
    }

    private func makeHistory() -> HistoryIndex {
        var h = HistoryIndex()
        h.byExercise = Dictionary(grouping: sets, by: \.exercise)
        h.byDay = Dictionary(grouping: sets) { dayKey($0.date) }
        for e in exercises {
            h.typeOf[e.name] = e.type
            h.muscleOf[e.name] = e.muscle
        }
        return h
    }

    // MARK: - Historie helpers

    /// Elke sessie een eigen id, afgeleid van het starttijdstip. Zo houdt een training
    /// die na een force-quit hervat wordt dezelfde sessie — `startedAt` komt mee terug —
    /// zonder dat het opslagformaat eromheen een veld erbij hoeft.
    private var workoutID: UUID { .stable(from: "workout-\(startedAt.timeIntervalSinceReferenceDate)") }

    /// De laatste 90 sessies, nieuwste eerst. Twee trainingen op één dag zijn twee
    /// kaarten; sets van vóór `workoutID` vallen nog per dag samen.
    private var pastSessions: [WorkoutSession] {
        Array(sets.sessions().reversed().prefix(90))
    }

    private func lastSession(for name: String, _ history: HistoryIndex) -> [SetEntry] {
        let prev = (history.byExercise[name] ?? []).filter { $0.date < startedAt }
        guard let latest = prev.max(by: { $0.date < $1.date }) else { return [] }
        return prev.filter { $0.sessionKey == latest.sessionKey }.sorted { $0.date < $1.date }
    }

    // Kalenderweek (ma–zo), dezelfde grens als waar het weekdoel op telt. Een rollend
    // venster van 7 dagen gaf een andere stand dan het dashboard.
    private var weekDays: [Date] {
        guard let week = cal.dateInterval(of: .weekOfYear, for: .now) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }
    }

    private var trainedThisWeek: Int {
        guard let week = cal.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return Set(sets.filter { week.contains($0.date) }.map { dayKey($0.date) }).count
    }

    private func routineSubtitle(_ routine: Routine) -> String {
        guard !routine.exercises.isEmpty else { return "Nog geen oefeningen — tik om toe te voegen" }
        return "\(routine.exercises.count) oefeningen · " + routine.exercises.prefix(3).joined(separator: ", ")
    }

    private func lastDone(_ routine: Routine) -> Date? {
        sets.filter { routine.exercises.contains($0.exercise) }.map(\.date).max()
    }

    private func sets(on day: Date, _ history: HistoryIndex) -> [SetEntry] {
        history.byDay[dayKey(day)] ?? []
    }

    /// Training met minstens één nieuw e1RM-record. Vanaf de eerste set van déze sessie,
    /// niet vanaf middernacht: anders krijgt de avondtraining het bekertje van de ochtend.
    private func isPRSession(_ session: WorkoutSession, _ history: HistoryIndex) -> Bool {
        let start = session.sets.first?.date ?? session.date
        // Per oefening één keer het oude record bepalen i.p.v. per set opnieuw scannen.
        var bestBefore: [String: Double] = [:]
        for s in session.sets {
            let best: Double
            if let cached = bestBefore[s.exercise] {
                best = cached
            } else {
                best = (history.byExercise[s.exercise] ?? [])
                    .filter { $0.date < start }
                    .map { epley($0.weightKg, $0.reps) }.max() ?? 0
                bestBefore[s.exercise] = best
            }
            if best > 0, epley(s.weightKg, s.reps) > best + 0.1 { return true }
        }
        return false
    }

    private func prCount(_ history: HistoryIndex) -> Int {
        workout.compactMap { prInfo($0, history) }.count
    }

    // MARK: - Doelgerichte voorstellen (dubbele progressie)

    private func draft(for name: String, target: [Int]? = nil, _ history: HistoryIndex) -> DraftExercise {
        let last = lastSession(for: name, history)
        let bw = history.isBodyweight(name)
        let goalSets = target.map { max($0.first ?? 3, 1) }
        let goalReps = target.flatMap { $0.count > 1 ? $0[1] : nil }
        // Cardio: één blok met een duur. Doel-reps zijn hier minuten.
        if history.isCardio(name) {
            let minutes = goalReps ?? last.compactMap { $0.seconds > 0 ? $0.seconds / 60 : nil }.max() ?? 20
            let tip = last.isEmpty ? "Log je minuten — kg en reps blijven leeg."
                                   : "Vorige keer \(last.map { $0.seconds / 60 }.max() ?? 0) min."
            return DraftExercise(name: name, tip: tip,
                                 sets: [DraftSet(kg: 0, reps: 0, seconds: minutes * 60)])
        }
        guard !last.isEmpty else {
            let n = goalSets ?? 3
            let reps = goalReps ?? 8
            let tip = bw ? "Eerste keer — log je reps (extra gewicht is optioneel)."
                         : "Eerste keer — kies een gewicht dat je \(reps) reps aankan."
            return DraftExercise(name: name, tip: tip,
                                 sets: (0..<n).map { _ in DraftSet(kg: bw ? 0 : 20, reps: reps) })
        }
        let top = last.map(\.weightKg).max() ?? (bw ? 0 : 20)
        let allEnough = last.allSatisfy { $0.reps >= (goalReps ?? 8) }
        // Bodyweight progresseert op reps, niet op gewicht.
        let tip = bw
            ? "Zelfde, probeer 1 rep meer per set."
            : (allEnough
               ? "Vorige keer alles gehaald → vandaag \((top + 2.5).kgText) kg"
               : "Zelfde gewicht, probeer 1 rep meer per set.")
        // Aantal sets uit het target (of het aantal van vorige keer), reps uit het target
        let count = goalSets ?? last.count
        return DraftExercise(name: name, tip: tip, sets: (0..<count).map { i in
            let prev = i < last.count ? last[i] : last.last
            let kg = bw ? top : (allEnough ? top + 2.5 : top)
            let reps = goalReps ?? (bw ? min((prev?.reps ?? 8) + 1, 30)
                                       : (allEnough ? 8 : min((prev?.reps ?? 8) + 1, 12)))
            return DraftSet(kg: kg, reps: reps,
                            previous: prev.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) })
        })
    }

    // PR op geschat 1RM (Epley): 8×60 telt dan ook als record t.o.v. 5×62,5
    /// Laatste notitie voor deze oefening, teruggevist uit de dagnotities
    /// (afronden schrijft ze als "Oefening: tekst").
    private func lastNote(for exercise: String, _ pastNotes: [DayHabits]) -> String? {
        let prefix = exercise + ": "
        for record in pastNotes {
            if let note = record.exerciseNotes[exercise], !note.isEmpty { return note }
            // Terugval voor notities van vóór `exerciseNotes`.
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
    /// Eén regel over hoe het met deze lift gaat — maar alleen als er iets te melden valt.
    /// Een regel die er altijd staat is decoratie; deze verschijnt bij een plateau of bij
    /// winst in de laatste 30 dagen, en zwijgt verder. De plateaudrempel komt uit
    /// `isPlateaued`, dezelfde die Inzicht gebruikt.
    private func progressNote(_ name: String, _ history: HistoryIndex) -> (text: String, warning: Bool)? {
        let past = (history.byExercise[name] ?? []).filter { $0.date < startedAt }
        guard !past.isEmpty else { return nil }
        let perSession = Dictionary(grouping: past) { $0.sessionKey }
            .map { (date: $0.value.first?.date ?? .distantPast, kg: $0.value.map { epley($0.weightKg, $0.reps) }.max() ?? 0) }
            .sorted { $0.date < $1.date }
        let values = perSession.map(\.kg)
        if isPlateaued(values) { return ("\(values.count >= 3 ? 3 : values.count) sessies geen record", true) }
        guard let monthAgo = cal.date(byAdding: .day, value: -30, to: .now) else { return nil }
        let before = perSession.filter { $0.date < monthAgo }.map(\.kg).max() ?? 0
        let recent = values.suffix(3).max() ?? 0
        guard before > 0, recent > before + 0.1 else { return nil }
        return ("+\((recent - before).kgText) kg 1RM deze maand", false)
    }

    private func lastSessionSummary(_ name: String, _ history: HistoryIndex) -> String? {
        let last = lastSession(for: name, history)
        guard !last.isEmpty else { return nil }
        let bw = history.isBodyweight(name)
        return last.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  ")
    }

    private func setRest(_ id: UUID, _ seconds: Int?) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        workout[i].restSeconds = seconds
    }

    /// Zelfde set er nog eens onder — kg/reps/duur en de vlaggetjes mee, maar nog niet afgevinkt.
    private func duplicateSet(exercise id: UUID, set setID: UUID) {
        guard let e = workout.firstIndex(where: { $0.id == id }),
              let s = workout[e].sets.firstIndex(where: { $0.id == setID }) else { return }
        let old = workout[e].sets[s]
        let copy = DraftSet(kg: old.kg, reps: old.reps, previous: old.previous,
                            warmup: old.warmup, dropset: old.dropset, failure: old.failure,
                            seconds: old.seconds)
        withAnimation(.snappy(duration: 0.25)) { workout[e].sets.insert(copy, at: s + 1) }
    }

    private func moveExercise(_ id: UUID, by offset: Int) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard workout.indices.contains(j) else { return }
        withAnimation(.snappy(duration: 0.25)) { workout.swapAt(i, j) }
    }

    /// Beste geschat 1RM voor deze oefening vóór de huidige sessie.
    private func bestBefore(_ name: String, _ history: HistoryIndex) -> Double? {
        (history.byExercise[name] ?? []).filter { $0.date < startedAt }
            .map { epley($0.weightKg, $0.reps) }.max()
    }

    /// Nieuw geschat 1RM-record t.o.v. je historie én eerdere sets deze sessie?
    private func isNewPR(exercise name: String, kg: Double, reps: Int, _ history: HistoryIndex) -> Bool {
        let now = epley(kg, reps)
        let historical = bestBefore(name, history) ?? 0
        let sessionBest = workout.first { $0.name == name }?.sets
            .filter { $0.done && !$0.warmup }.map { epley($0.kg, $0.reps) }.max() ?? 0
        return now > max(historical, sessionBest) + 0.1 && historical > 0
    }

    private func prInfo(_ ex: DraftExercise, _ history: HistoryIndex) -> (new: Double, old: Double)? {
        guard let doneMax = ex.sets.filter({ $0.done && !$0.warmup }).map({ epley($0.kg, $0.reps) }).max() else { return nil }
        guard let prev = bestBefore(ex.name, history), doneMax > prev + 0.1 else { return nil }
        return (doneMax, prev)
    }

    // MARK: - Acties

    private func addTemplate(_ routines: [(String, [String])]) {
        for (name, exercises) in routines {
            context.insert(Routine(name: name, exercises: exercises))
        }
    }

    // Wordt bij elke render opgebouwd en Equatable vergeleken, maar loopt alleen over de
    // sets van de lópende training (tientallen, geen duizenden) — dat is microseconden.
    // Bewust zo gelaten: dit is wat een force-quit midden in een set opvangt.
    private var draftSnapshot: SavedWorkout? {
        guard active else { return nil }
        return SavedWorkout(startedAt: startedAt, exercises: workout.map { ex in
            .init(name: ex.name, tip: ex.tip, note: ex.note,
                  sets: ex.sets.map { .init(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, warmup: $0.warmup, dropset: $0.dropset, failure: $0.failure, seconds: $0.seconds, entryID: $0.savedEntry?.syncID) },
                  originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }, alternatives: alternatives.isEmpty ? nil : alternatives,
           restEndsAt: workoutStatus.restEndsAt,
           workoutNote: workoutNote.isEmpty ? nil : workoutNote,
                     workoutName: workoutName.isEmpty ? nil : workoutName,
                     workoutDate: dayKey(workoutDate) == dayKey(.now) ? nil : workoutDate)
    }

    /// Na een force-quit: training terugzetten en de Live Activity weer adopteren.
    private func restoreDraft() {
        guard !active,
              let data = UserDefaults.standard.data(forKey: "activeWorkout"),
              let saved = try? JSONDecoder().decode(SavedWorkout.self, from: data) else { return }
        startedAt = saved.startedAt
        // De rijen die al in de database staan weer aan hun set koppelen. Zonder dat is
        // een herstelde training niet meer te verzetten, te annuleren of af te vinken.
        let byID = Dictionary(sets.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        workout = saved.exercises.map { ex in
            DraftExercise(name: ex.name, tip: ex.tip,
                          sets: ex.sets.map { DraftSet(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, savedEntry: $0.entryID.flatMap { id in byID[id] }, warmup: $0.warmup ?? false, dropset: $0.dropset ?? false, failure: $0.failure ?? false, seconds: $0.seconds ?? 0) },
                          note: ex.note, originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }
        alternatives = saved.alternatives ?? [:]
        workoutNote = saved.workoutNote ?? ""
        workoutName = saved.workoutName ?? ""
        workoutDate = saved.workoutDate ?? .now
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

    // Onderstaande drie zijn event-handlers, geen render-pad: hier is de index één keer
    // opbouwen goedkoper dan 'm doorgeven vanuit body.
    private func swapExercise(_ id: UUID, to newName: String) {
        guard let i = workout.firstIndex(where: { $0.id == id }) else { return }
        let original = workout[i].originalName ?? workout[i].name
        var replacement = draft(for: newName, makeHistory())
        replacement.originalName = original
        withAnimation(.snappy(duration: 0.25)) { workout[i] = replacement }
    }

    private func startWorkout(with names: [String], alternatives alts: [String: [String]] = [:],
                             targets: [String: [Int]] = [:], supersets: [String: String] = [:],
                             restByExercise: [String: Int] = [:]) {
        startedAt = .now
        // Anders erft deze training de datum van het moment waarop de view gebouwd werd
        // (app-start) of van een eerder geannuleerde teruggedateerde sessie, en verhuist
        // `applyWorkoutDate` 'm bij het afronden naar een dag die je nooit gekozen hebt.
        workoutDate = .now
        workoutNote = ""
        let history = makeHistory()
        workout = names.map { name in
            var d = draft(for: name, target: targets[name], history)
            d.superset = supersets[name]
            d.restSeconds = restByExercise[name]
            return d
        }
        alternatives = alts
        WorkoutStatus.shared.startWorkout(at: startedAt)
        withAnimation(.snappy(duration: 0.3)) { active = true }
    }

    private func addExercise(_ name: String) {
        let d = draft(for: name, makeHistory())
        withAnimation(.snappy(duration: 0.25)) { workout.append(d) }
    }

    private func removeExercise(_ id: DraftExercise.ID) {
        if let ex = workout.first(where: { $0.id == id }) {
            for s in ex.sets { if let e = s.savedEntry, !e.isDeleted { context.deleteSynced(e) } }
        }
        withAnimation(.snappy(duration: 0.25)) { workout.removeAll { $0.id == id } }
    }

    /// Verhuist de sets naar de gekozen datum. De onderlinge afstand blijft staan, zodat
    /// de volgorde binnen de sessie klopt en de historie er hetzelfde uitziet als wanneer
    /// je 'm live had gelogd. Alles wat "heb ik die dag getraind?" beantwoordt — score,
    /// streak, weekplanning — leest de datum van de sets, dus dit is de enige knop die om
    /// hoeft.
    private func applyWorkoutDate() {
        guard dayKey(workoutDate) != dayKey(.now) else { return }
        for set in workout.flatMap(\.sets) {
            guard let entry = set.savedEntry, !entry.isDeleted else { continue }
            entry.date = workoutDate.addingTimeInterval(entry.date.timeIntervalSince(startedAt))
        }
    }

    private func saveExerciseNotes() {
        let notes = workout
            .map { ($0.name, $0.note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        guard !notes.isEmpty else { return }
        let record = context.habits(on: workoutDate)
        for (name, text) in notes { record.exerciseNotes[name] = text }
    }

    /// Naam en algemene notitie op de dag bewaren (los van de per-oefening notities).
    private func saveWorkoutNote() {
        let clean = workoutNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = workoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || !name.isEmpty else { return }
        // Per sessie, niet per dag: anders overschrijft je avondtraining de naam van
        // die ochtend.
        let record = context.habits(on: workoutDate)
        if !clean.isEmpty { record.workoutNotes[workoutID.uuidString] = clean }
        if !name.isEmpty { record.workoutNames[workoutID.uuidString] = name }
    }

    /// Spiergroep-intensiteit van de zojuist afgeronde training (0…1, genormaliseerd op volume).
    private func sessionMuscles(_ history: HistoryIndex) -> [String: Double] {
        let muscleOf = history.muscleOf
        var totals: [String: Double] = [:]
        for ex in workout {
            let m = muscleOf[ex.originalName ?? ex.name] ?? muscleOf[ex.name] ?? "Overig"
            let bw = history.isBodyweight(ex.name)
            let vol = ex.sets.filter { $0.done && !$0.warmup }
                .map { liftLoad(kg: $0.kg, bodyweight: bodyWeight, bodyweightExercise: bw) * Double($0.reps) }.reduce(0, +)
            if vol > 0 { totals[m, default: 0] += vol }
        }
        guard let maxV = totals.values.max(), maxV > 0 else { return [:] }
        return totals.mapValues { $0 / maxV }
    }

    private func finishWorkout() {
        applyWorkoutDate()
        saveExerciseNotes()
        saveWorkoutNote()
        WorkoutStatus.shared.endWorkout()
        let history = makeHistory()
        // Vergelijk met de vorige sessie die minstens één oefening deelt — niet met een
        // willekeurige vorige dag (anders vergelijk je Legs met Push).
        let names = Set(workout.map(\.name))
        // Alles behalve deze sessie zelf. Op "niet vandaag" filteren sloeg een training
        // van diezelfde ochtend over, en dat is juist de meest recente vergelijking.
        let previous = pastSessions.first { s in
            s.id != workoutID.uuidString && s.sets.contains { names.contains($0.exercise) }
        }
        let previousVolume = previous.map { s in
            Int(s.sets.map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight, bodyweightExercise: history.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
        }
        summary = WorkoutSummary(
            minutes: max(Int(Date.now.timeIntervalSince(startedAt) / 60), 1),
            volume: volume(history),
            sets: doneCount,
            prs: workout.compactMap { ex in prInfo(ex, history).map { (ex.name, $0.new, $0.old) } },
            previousVolume: previousVolume,
            muscles: sessionMuscles(history),
            lines: workout.compactMap { ex in
                let done = ex.sets.filter { $0.done && !$0.warmup }
                guard !done.isEmpty else { return nil }
                let bw = history.isBodyweight(ex.name)
                return "\(ex.name): " + done.map { setNotation(kg: $0.kg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  ")
            }
        )
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
            workoutNote = ""
            workoutName = ""
            workoutDate = .now
        }
        syncNow()
    }

    private func discardWorkout() {
        WorkoutStatus.shared.endWorkout()
        for s in workout.flatMap(\.sets) {
            if let e = s.savedEntry, !e.isDeleted { context.deleteSynced(e) }
        }
        withAnimation(.snappy(duration: 0.3)) {
            active = false
            workout = []
            workoutNote = ""
        }
        syncNow()
    }

    /// De sync-lus slaat een lopende training over — anders pushte hij bij elke afgevinkte
    /// set de volledige historie. Einde training is het moment waarop het wél moet.
    private func syncNow() {
        Sync.markDirty() // de autosave kan nog moeten komen; niet op z'n melding wachten
        Task { await Sync.pushIfChanged(context, force: true) }
    }

    private var doneCount: Int { workout.flatMap(\.sets).filter { $0.done && !$0.warmup }.count }
    private func volume(_ history: HistoryIndex) -> Int {
        var total = 0.0
        for ex in workout {
            let bw = history.isBodyweight(ex.name)
            for s in ex.sets where s.done && !s.warmup {
                total += liftLoad(kg: s.kg, bodyweight: bodyWeight, bodyweightExercise: bw) * Double(s.reps)
            }
        }
        return Int(total)
    }

    // MARK: - Body

    /// Een lopende training kun je inklappen: dan staat het overzicht er weer, met de
    /// "Training bezig"-balk als weg terug. `active` blijft ondertussen aan — de sets, de
    /// tijd en de rusttimer lopen door.
    private var showingWorkout: Bool { active && !workoutStatus.minimized }

    /// Actieve training blijft een List: swipe-to-delete op sets bestaat daarbuiten
    /// niet, en tijdens het loggen wil je juist een dichte lijst.
    @ViewBuilder private func screen(_ history: HistoryIndex, _ pastNotes: [DayHabits]) -> some View {
        if showingWorkout {
            List { activeSections(history, pastNotes) }
        } else {
            ScrollView {
                LazyVStack(spacing: 14) { idleContent(history) }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    private var content: some View {
        // Eén groepering per render; elke helper hieronder zocht hiervoor zelf de
        // volledige sets-tabel af, meerdere keren per oefening.
        let history = makeHistory()
        let prCount = prCount(history)
        // Dagnotities één keer sorteren i.p.v. per oefening in de kop.
        let pastNotes = habits
            .filter { !cal.isDateInToday($0.date) && !($0.exerciseNotes.isEmpty && $0.note.isEmpty) }
            .sorted { $0.date > $1.date }
        return screen(history, pastNotes)
        .navigationTitle("Training")
        .navigationBarTitleDisplayMode(showingWorkout ? .inline : .large)
        .toolbar(showingWorkout ? .automatic : .hidden, for: .navigationBar) // idle heeft z'n eigen titel
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Klaar") {
                    focusedSet = nil
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                .font(.body.bold())
            }
            if showingWorkout {
                ToolbarItem(placement: .principal) {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    // Inklappen, niet afsluiten: je routines en je historie staan achter
                    // dit scherm, en daar wil je tijdens een training ook bij.
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { workoutStatus.minimized = true }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Naar het overzicht")
                    Button { showStopwatch = true } label: {
                        Image(systemName: "stopwatch")
                    }
                    .accessibilityLabel("Stopwatch")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Gevulde knop: dit is de primaire actie van het scherm, en als kale
                    // tekst was hij niet van z'n eigen disabled-staat te onderscheiden.
                    Button("Afronden") { finishWorkout() }
                        .font(.subheadline.bold())
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(doneCount == 0)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Rust-balk óf de ingeklapte "Training bezig"-balk overlapt anders de onderste rijen
            if workoutStatus.restEndsAt != nil || (active && workoutStatus.minimized) {
                Color.clear.frame(height: 68)
            }
        }
        .task { restoreDraft() }
        .sheet(isPresented: $showStopwatch) {
            StopwatchSheet()
                .presentationDetents([.height(400)])
        }
        .sheet(item: $detailExercise) { item in
            NavigationStack {
                ExerciseDetailView(exercise: item.name)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Sluit") { detailExercise = nil }
                        }
                    }
            }
        }
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
        .confirmationDialog("Training verwijderen?",
                            isPresented: Binding(get: { sessionToDelete != nil },
                                                 set: { if !$0 { sessionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \(sessionToDelete?.sets.count ?? 0) sets", role: .destructive) {
                for s in sessionToDelete?.sets ?? [] { context.deleteSynced(s) }
                sessionToDelete = nil
            }
            Button("Annuleer", role: .cancel) { sessionToDelete = nil }
        }
        .confirmationDialog("Oefening verwijderen?",
                            isPresented: Binding(get: { exerciseToRemove != nil },
                                                 set: { if !$0 { exerciseToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder oefening en sets", role: .destructive) {
                if let id = exerciseToRemove { removeExercise(id) }
                exerciseToRemove = nil
            }
            Button("Annuleer", role: .cancel) { exerciseToRemove = nil }
        } message: {
            Text("Je hebt al sets afgevinkt voor deze oefening. Die worden ook verwijderd.")
        }
        .sheet(item: $summary) { s in
            WorkoutSummarySheet(summary: s, name: profile.name)
        }
        .navigationDestination(item: $editingRoutine) { routine in
            // Loopt er al een training, dan verdwijnt de startknop: bekijken en bewerken
            // mag, maar een tweede training zou de eerste overschrijven.
            RoutineEditorView(routine: routine, onStart: active ? nil : { r in
                editingRoutine = nil
                startWorkout(with: r.exercises, alternatives: r.alternatives, targets: r.targets,
                             supersets: r.supersets, restByExercise: r.restByExercise)
            })
        }
        .sheet(isPresented: $showExercisePicker) {
            // ponytail: geen exclude — dezelfde oefening twee keer in één training mag
            // (bench voor en na de superset, tweede ronde curls). Rijen zijn op id, dus
            // duplicaten staan los van elkaar; opgeslagen sets groeperen later op naam.
            ExercisePickerSheet { name in
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

    // MARK: - Idle: kaarten i.p.v. een List, zodat de tab niet leest als Instellingen

    /// Eén weekstrip: wat je deze week deed, en hoe ver dat van je weekdoel af staat.
    private func weekCard(_ history: HistoryIndex) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Deze week").font(.headline)
                Spacer()
                Text("\(trainedThisWeek) van \(profile.trainingsPerWeek)")
                    .font(.footnote.bold().monospacedDigit())
                    .foregroundStyle(trainedThisWeek >= profile.trainingsPerWeek ? .green : .secondary)
            }
            HStack(spacing: 6) {
                ForEach(weekDays, id: \.self) { day in
                    weekDay(day, history)
                }
            }
        }
        .builtCard()
    }

    /// Eén dag: getraind (vol, in de kleur van wat je deed) of niet. Er valt niets te
    /// koppelen — welke dag je traint bepaal je door te trainen.
    private func weekDay(_ day: Date, _ history: HistoryIndex) -> some View {
        let done = sets(on: day, history)
        let did = !done.isEmpty
        let routine = done.first.flatMap { s in routines.first { $0.exercises.contains(s.exercise) } }
        let tint = routine.map { routineColor($0, history) } ?? .green
        let isToday = cal.isDateInToday(day)

        return VStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.primary : Color.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous)
                    .fill(did ? AnyShapeStyle(tint) : AnyShapeStyle(.builtTint(.gray)))
                    .frame(height: 46)
                if did {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
                if isToday {
                    RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous)
                        .strokeBorder(.green, lineWidth: 2)
                        .frame(height: 46)
                }
            }
            Text(day.formatted(.dateTime.day()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? Color.green : Color.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month()))
        .accessibilityValue(did ? "Getraind" : "Niet getraind")
    }

    // MARK: - Routine-identiteit

    /// Dominante spiergroep bepaalt de kleur — zo herken je Push van Legs zonder te lezen.
    private func routineColor(_ routine: Routine, _ history: HistoryIndex) -> Color {
        var tally: [String: Int] = [:]
        for name in routine.exercises { tally[history.muscleOf[name] ?? "Overig", default: 0] += 1 }
        guard let top = tally.max(by: { $0.value < $1.value })?.key else { return .green }
        return .muscle(top)
    }

    private func routineIcon(_ routine: Routine, _ history: HistoryIndex) -> String {
        guard !routine.exercises.isEmpty else { return "square.and.pencil" }
        var tally: [String: Int] = [:]
        for name in routine.exercises { tally[history.typeOf[name] ?? "Overig", default: 0] += 1 }
        let top = tally.max { $0.value < $1.value }?.key ?? "Overig"
        return Exercise.typeIcon[top] ?? "dumbbell"
    }

    private func routineCard(_ routine: Routine, _ history: HistoryIndex) -> some View {
        let tint = routineColor(routine, history)
        return Button {
            editingRoutine = routine // preview: bekijken, bewerken of starten
        } label: {
            HStack(spacing: 14) {
                // Gekleurde balk links (Equinox/Runna) + tegel: routine krijgt een gezicht
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 4)
                RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous)
                    .fill(.builtTint(tint))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: routineIcon(routine, history))
                            .font(.subheadline)
                            .foregroundStyle(tint)
                    }
                    .accessibilityHidden(true)
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
                    if !routine.exercises.isEmpty, !active {
                        Button("Start meteen", systemImage: "play.fill") {
                            startWorkout(with: routine.exercises, alternatives: routine.alternatives,
                                         targets: routine.targets, supersets: routine.supersets,
                                         restByExercise: routine.restByExercise)
                        }
                    }
                    Button("Wijzig routine", systemImage: "pencil") { editingRoutine = routine }
                    Button("Verwijder routine", systemImage: "trash", role: .destructive) {
                        context.deleteSynced(routine)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Acties voor \(routine.name)")
            }
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .padding(.leading, 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: BuiltRadius.card, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private func historyCard(_ session: WorkoutSession, _ history: HistoryIndex) -> some View {
        let day = cal.startOfDay(for: session.date)
        let vol = Int(session.sets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
        let name = habits.first { dayKey($0.date) == dayKey(session.date) }?.name(for: session.id) ?? ""
        return NavigationLink {
            SessionDetailView(session: session)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    // Tweede training van dezelfde dag: alleen de datum zegt te weinig.
                    Text(name.isEmpty ? session.date.formatted(date: .omitted, time: .shortened) : name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isPRSession(session, history) {
                        Text("🏆").font(.caption).accessibilityLabel("Persoonlijk record")
                    }
                    Spacer()
                    Text("\(vol) kg")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(session.sets.byExercise(), id: \.name) { group in
                    let bw = history.isBodyweight(group.name)
                    Text("\(group.name): " + group.sets.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .builtCard()
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        // Swipe-to-delete bestaat niet buiten een List; een hele trainingsdag wegvegen
        // was sowieso te makkelijk voor iets onomkeerbaars.
        .contextMenu {
            Button("Verwijder deze training", systemImage: "trash", role: .destructive) { sessionToDelete = session }
        }
    }

    @ViewBuilder private func idleContent(_ history: HistoryIndex) -> some View {
        let weekTitle = trainedThisWeek >= profile.trainingsPerWeek
            ? "Week rond 💪" : "Week \(profile.daysIn / 7 + 1)"
        BuiltScreenTitle(eyebrow: "Training", title: weekTitle) {
            Menu {
                Button("Nieuwe routine…", systemImage: "plus") { showNewRoutine = true }
                Divider()
                Button("Template: Push / Pull / Legs") { addTemplate(Self.pplTemplate) }
                Button("Template: Upper / Lower") { addTemplate(Self.ulTemplate) }
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(width: 36, height: 36)
                    .background(.builtTint(.green), in: Circle())
            }
            .accessibilityLabel("Routine toevoegen")
        }

        weekCard(history)

        // Ingeklapte training: geen tweede startknop, maar wel zeggen waar de eerste
        // gebleven is. De balk onderaan is de weg terug.
        if active {
            BuiltFootnote("Je training loopt nog — tik onderaan op \u{201C}Training bezig\u{201D} om verder te gaan.")
        } else {
            Button {
                startWorkout(with: [])
            } label: {
                Label("Lege training starten", systemImage: "plus")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.builtTint(.green), in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }

        // Naslag, geen actie — vandaar boven Routines en niet onder de historie van 90
        // sessies. Stond hiervoor in Instellingen, waar je afstelt in plaats van opzoekt.
        NavigationLink {
            ExerciseLibraryView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dumbbell")
                    .font(.body)
                    .foregroundStyle(.green)
                    .frame(width: 32, height: 32)
                    .background(.builtTint(.green), in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
                Text("Oefeningen").font(.subheadline.bold()).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .builtCard()
        }
        .buttonStyle(PressableStyle())

        BuiltSectionHeader("Routines")
        if routines.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView {
                    Label("Nog geen routines", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Een routine is een vaste set oefeningen. Begin met een template of maak er zelf een.")
                } actions: {
                    Button("Nieuwe routine") { showNewRoutine = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                HStack(spacing: 10) {
                    templateButton("Push / Pull / Legs", Self.pplTemplate)
                    templateButton("Upper / Lower", Self.ulTemplate)
                }
            }
            .builtCard()
        }
        ForEach(routines) { routine in
            routineCard(routine, history)
        }

        BuiltSectionHeader("Geschiedenis")
        if pastSessions.isEmpty {
            ContentUnavailableView("Nog geen trainingen", systemImage: "clock.arrow.circlepath",
                                   description: Text("Je eerste training verschijnt hier — met volume, oefeningen en records."))
                .builtCard()
        }
        ForEach(pastSessions) { session in
            historyCard(session, history)
        }
    }

    private func templateButton(_ title: String, _ template: [(String, [String])]) -> some View {
        Button {
            addTemplate(template)
        } label: {
            Text(title)
                .font(.footnote.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.builtTint(.green), in: Capsule())
                .foregroundStyle(.green)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Actieve training (Hevy Log Workout)

    @ViewBuilder private func activeSections(_ history: HistoryIndex, _ pastNotes: [DayHabits]) -> some View {
        // Geen statkaart meer tijdens het loggen: de duur staat in de balk, en volume en
        // sets komen in de samenvatting bij het afronden. Drie tegels die aan het begin
        // "0 kg" en "0" zeiden duwden je eerste oefening onder de vouw.
        if doneCount == 0 {
            Section {
                Text("Vink een set af om te kunnen afronden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach($workout) { $ex in
            exerciseSection($ex, history, pastNotes)
        }

        Section {
            Button {
                showExercisePicker = true
            } label: {
                Label("Oefening toevoegen", systemImage: "plus")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }

        // Ingeklapt: drie altijd-open velden namen een scherm in beslag voor iets wat je
        // hooguit één keer per training invult. De datum blijft wel in de voet staan als
        // hij niet vandaag is — dat mag nooit verstopt zitten.
        Section {
            DisclosureGroup {
                TextField("Naam (bijv. Push A)", text: $workoutName)
                // Vergeten te loggen? Zet de datum terug en de sessie landt op de juiste dag,
                // inclusief het trainingsvinkje in je score.
                DatePicker("Datum", selection: $workoutDate, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                TextField("Notitie (bijv. voelde sterk)", text: $workoutNote, axis: .vertical)
                    .lineLimit(1...6)
            } label: {
                LabeledContent("Deze training") {
                    Text(workoutName.isEmpty ? "Naamloos" : workoutName)
                }
            }
        } footer: {
            if !cal.isDateInToday(workoutDate) {
                Text("Deze training wordt gelogd op \(workoutDate.formatted(date: .long, time: .shortened)).")
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
    private func updateActivity(_ id: DraftExercise.ID, currentKg: Double, _ history: HistoryIndex) {
        guard let ex = workout.first(where: { $0.id == id }) else { return }
        let name = ex.name
        WorkoutStatus.shared.updateContext(exercise: name,
                                           setsDone: ex.sets.filter(\.done).count,
                                           setsTotal: ex.sets.count,
                                           tip: activityTip(for: name, currentKg: currentKg, history))
    }

    private func activityTip(for name: String, currentKg: Double, _ history: HistoryIndex) -> String? {
        let last = lastSession(for: name, history)
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

    /// Eén oefening in de actieve training. Los van `activeSections` omdat de
    /// type-checker afhaakt op een ForEach-closure van deze omvang.
    @ViewBuilder private func exerciseSection(_ exercise: Binding<DraftExercise>, _ history: HistoryIndex,
                                              _ pastNotes: [DayHabits]) -> some View {
        let ex = exercise.wrappedValue
        let bodyweight = history.isBodyweight(ex.name)
        let cardio = history.isCardio(ex.name)
        let numbers = setNumbers(ex.sets)
        // Beide closures één `some View`-expressie: anders kiest de compiler de
        // TableRow-variant van Section en klapt de type-inferentie eruit.
        Section {
            exerciseRows(exercise, history, pastNotes, bodyweight: bodyweight, cardio: cardio, numbers: numbers)
        } header: {
            exerciseHeader(exercise, history, cardio: cardio)
        }
    }

    /// De rijen van één oefening: notitie, kolomkoppen, sets, schijven en 'set toevoegen'.
    @ViewBuilder private func exerciseRows(_ exercise: Binding<DraftExercise>, _ history: HistoryIndex,
                                           _ pastNotes: [DayHabits],
                                           bodyweight: Bool, cardio: Bool, numbers: [UUID: Int]) -> some View {
        let ex = exercise.wrappedValue
        if let previousNote = lastNote(for: ex.name, pastNotes) {
            Label("Vorige keer: \u{201C}\(previousNote)\u{201D}", systemImage: "text.quote")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        TextField("Notitie (bijv. voelde zwaar)", text: exercise.note, axis: .vertical)
            .font(.footnote)
            .listRowSeparator(.hidden)
        HStack(spacing: 12) {
            Text("SET").frame(width: 24, alignment: .leading)
            Text("VORIGE").frame(width: 64, alignment: .leading)
            if cardio {
                Text("MINUTEN").frame(width: 56)
            } else {
                Text(bodyweight ? "±KG" : "KG").frame(width: 56)
                Text("REPS").frame(width: 48)
            }
            Spacer()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .listRowSeparator(.hidden)

        ForEach(exercise.sets) { $set in
            setRow($set, number: numbers[set.id] ?? 0, exercise: ex.name, exerciseID: ex.id,
                   bodyweight: bodyweight, cardio: cardio, history: history,
                   duplicate: { duplicateSet(exercise: ex.id, set: set.id) })
        }
        .onDelete { offsets in
            for i in offsets {
                if let e = ex.sets[i].savedEntry, !e.isDeleted { context.deleteSynced(e) }
            }
            exercise.wrappedValue.sets.remove(atOffsets: offsets)
        }

        if history.isBarbell(ex.name),
           let top = ex.sets.filter({ !$0.warmup }).map(\.kg).max(),
           let plates = platesPerSide(total: top) {
            let approx = abs((20 + 2 * plates.reduce(0, +)) - top) < 0.05 ? "" : "≈ "
            let body = plates.isEmpty ? "alleen de 20 kg stang"
                                     : "per kant \(plates.map(\.kgText).joined(separator: " + ")) · 20 kg stang"
            Label("\(approx)\(body)", systemImage: "scalemass")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .listRowSeparator(.hidden)
        }

        Button {
            let last = ex.sets.last ?? DraftSet(kg: 20, reps: 8)
            let new = DraftSet(kg: last.kg, reps: last.reps, previous: nil)
            withAnimation(.snappy(duration: 0.2)) { exercise.wrappedValue.sets.append(new) }
            focusedSet = new.id
        } label: {
            // Groen betekent op dit scherm precies één ding: afgevinkt. Toevoegknoppen en
            // setnummers pikten die kleur mee via de app-tint.
            Label("Set toevoegen", systemImage: "plus")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Kop van een oefening: naam, PR-badge, vorige sessie en het ⋯-menu.
    @ViewBuilder private func exerciseHeader(_ exercise: Binding<DraftExercise>, _ history: HistoryIndex,
                                             cardio: Bool) -> some View {
        let ex = exercise.wrappedValue
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let group = ex.superset {
                        Text("Superset \(group)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.builtTint(.green), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    // `Color.primary`, niet `.primary`: in een sectiekop staat de
                    // foreground al op secondary, en het hiërarchische `.primary` lost
                    // dan óók naar grijs op. De kop van het blok was het lichtste
                    // element op het scherm.
                    // Tikbaar: hier wil je je verloop zien, en tot nu toe kon dat alleen
                    // vanuit Inzicht, Records of het Logboek — nooit tijdens het tillen.
                    Button {
                        detailExercise = ExerciseName(ex.name)
                    } label: {
                        HStack(spacing: 3) {
                            Text(ex.name)
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Toont je voortgang voor deze oefening")
                }
                if let note = progressNote(ex.name, history) {
                    Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(note.warning ? .orange : .green)
                }
                if let pr = prInfo(ex, history) {
                    Text("🏆 Nieuw record — geschat 1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if let tip = ex.tip {
                    Text(tip).font(.caption).foregroundStyle(.secondary)
                }
                if let prev = lastSessionSummary(ex.name, history) {
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
                if !cardio {
                    if ex.sets.contains(where: \.warmup) {
                        Button("Warming-up weghalen", systemImage: "flame") { removeWarmup(ex.id) }
                    } else {
                        Button("Warming-up toevoegen", systemImage: "flame") { addWarmup(ex.id) }
                    }
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
                    if ex.sets.contains(where: { $0.done && !$0.warmup }) { exerciseToRemove = ex.id }
                    else { removeExercise(ex.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 20)
            }
            .accessibilityLabel("Acties voor \(ex.name)")
        }
        .textCase(nil) // ponytail: headers uppercasen anders ook het ⋯-menu
    }

    /// Werkset-nummer per set-id, in één pass. Stond eerder per rij als
    /// `sets[...idx].filter { !$0.warmup }.count` — kwadratisch over de sets.
    private func setNumbers(_ sets: [DraftSet]) -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        var n = 0
        for s in sets {
            if !s.warmup { n += 1 }
            out[s.id] = n
        }
        return out
    }

    private func setLabel(_ set: DraftSet, number: Int) -> String {
        if set.warmup { return "W" }
        var s = "\(number)"
        if set.dropset { s += " D" }
        if set.failure { s += " F" }
        return s
    }

    /// De al opgeslagen rij van deze set, als die er is en nog bestaat.
    private func saved(_ set: Binding<DraftSet>) -> SetEntry? {
        guard let e = set.wrappedValue.savedEntry, !e.isDeleted else { return nil }
        return e
    }

    private func setRow(_ set: Binding<DraftSet>, number: Int, exercise: String, exerciseID: DraftExercise.ID,
                        bodyweight: Bool, cardio: Bool, history: HistoryIndex,
                        duplicate: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Menu {
                Button("Set dupliceren", systemImage: "plus.square.on.square", action: duplicate)
                if !cardio {
                    Divider()
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
            .tint(Color.secondary) // menu-label pikte anders de groene app-tint mee
            Text(set.wrappedValue.previous ?? "—")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
                .opacity(set.wrappedValue.done ? 0.55 : 1)
            // De velden blijven bewerkbaar ná het afvinken. Ze stonden op `disabled`, en
            // een typefout herstelde je dus door af te vinken (rij weg uit de database) en
            // opnieuw aan te vinken (nieuwe rij, nieuwe tijdstempel). De bindings schrijven
            // nu door naar de al opgeslagen rij.
            if cardio {
                NumericField(value: Binding(get: { Double(set.wrappedValue.seconds / 60) },
                                            set: { v in
                                                let secs = Int(min(v.rounded(), 600)) * 60
                                                set.wrappedValue.seconds = secs
                                                saved(set)?.seconds = secs
                                            }),
                             decimal: false, placeholder: "min",
                             focus: $focusedSet, id: set.wrappedValue.id)
                    .numericFieldChrome(width: 56, dimmed: set.wrappedValue.done)
                Text("min").font(.footnote).foregroundStyle(.secondary)
            } else {
                NumericField(value: Binding(get: { set.wrappedValue.kg },
                                            set: { v in
                                                set.wrappedValue.kg = v
                                                saved(set)?.weightKg = v
                                            }),
                             decimal: true, placeholder: bodyweight ? "±kg" : "kg",
                             focus: $focusedSet, id: set.wrappedValue.id, signed: bodyweight)
                    .numericFieldChrome(width: 56, dimmed: set.wrappedValue.done)
                NumericField(value: Binding(get: { Double(set.wrappedValue.reps) },
                                            set: { v in
                                                let reps = Int(min(v.rounded(), 9999))
                                                set.wrappedValue.reps = reps
                                                saved(set)?.reps = reps
                                            }),
                             decimal: false, placeholder: "reps",
                             focus: $focusedSet, id: nil)
                    .numericFieldChrome(width: 48, dimmed: set.wrappedValue.done)
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    set.wrappedValue.done.toggle()
                    if set.wrappedValue.done {
                        if !set.wrappedValue.warmup {
                            let e = SetEntry(exercise: exercise, weightKg: set.wrappedValue.kg, reps: set.wrappedValue.reps,
                                             dropset: set.wrappedValue.dropset, failure: set.wrappedValue.failure,
                                             seconds: set.wrappedValue.seconds, workoutID: workoutID)
                            context.insert(e)
                            set.wrappedValue.savedEntry = e
                        }
                        // Warming-up, cardio en tussen-superset-sets: geen (of minimale) rust
                        if !set.wrappedValue.warmup, !cardio, shouldRest(after: exercise) {
                            WorkoutStatus.shared.startRest(seconds: restFor(exercise))
                        }
                        if !set.wrappedValue.warmup, !cardio,
                           isNewPR(exercise: exercise, kg: set.wrappedValue.kg, reps: set.wrappedValue.reps, history) {
                            prToast = "🏆 Record — \(exercise)!"
                        }
                    } else {
                        // Op kg/reps zoeken was hier de terugval voor een herstelde
                        // training. Bij 3×10 @ 60 kg matcht dat op elke set, en `sets`
                        // staat aflopend op datum: je haalde het vinkje van de eerste weg
                        // en de rij van de derde verdween. De koppeling komt nu uit
                        // `SavedWorkout`, dus deze gok is niet meer nodig.
                        if let e = set.wrappedValue.savedEntry, !e.isDeleted { context.deleteSynced(e) }
                        set.wrappedValue.savedEntry = nil
                    }
                    updateActivity(exerciseID, currentKg: set.wrappedValue.kg, history)
                }
            } label: {
                Image(systemName: set.wrappedValue.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(set.wrappedValue.done ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.wrappedValue.done ? "Set afgevinkt" : "Set afvinken")
        }
        .listRowBackground(set.wrappedValue.done ? Color.builtTint(.green) : nil)
    }
}
