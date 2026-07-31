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
    /// Duur voor cardio in seconden; 0 = krachtset.
    var seconds = 0
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
        var seconds: Int?
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
    /// Algemene notitie voor de hele sessie.
    var workoutNote: String?
}

struct WorkoutSummary: Identifiable {
    let id = UUID()
    let minutes: Int
    let volume: Int
    let sets: Int
    let prs: [(exercise: String, new: Double, old: Double)]
    var previousVolume: Int?
    var muscles: [String: Double] = [:]
    /// "Bench Press: 60×8  60×8" per oefening — voor het deelbericht.
    var lines: [String] = []

    var shareText: String {
        workoutShareText(title: "Training van \(Date.now.formatted(.dateTime.weekday(.wide).day().month()))",
                         duration: "\(minutes) min", volume: volume, sets: sets, lines: lines, prs: prs)
    }
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
    @State private var startedAt = Date.now
    @State private var summary: WorkoutSummary?
    @State private var editingRoutine: Routine?
    @State private var showExercisePicker = false
    @State private var showNewRoutine = false
    @State private var newRoutineName = ""
    @State private var confirmDiscard = false
    @State private var dayToDelete: Date?
    @State private var exerciseToRemove: DraftExercise.ID?
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

    // MARK: - Historie-index
    //
    // Elke helper hieronder filterde eerder de volledige sets-tabel, en dat per oefening
    // én per historie-dag, bij élke render. Nu wordt er één keer per render gegroepeerd.

    /// Sets per oefening en per dag, plus de oefening-catalogus als opzoektabel.
    struct HistoryIndex {
        var byExercise: [String: [SetEntry]] = [:]
        var byDay: [Int: [SetEntry]] = [:]
        /// Beste geschat 1RM per oefening vóór een gegeven dag — voor de PR-badges.
        var typeOf: [String: String] = [:]
        var muscleOf: [String: String] = [:]

        func isBodyweight(_ name: String) -> Bool { typeOf[name] == "Bodyweight" }
        func isBarbell(_ name: String) -> Bool { typeOf[name] == "Barbell" }
        func isCardio(_ name: String) -> Bool { typeOf[name] == "Cardio" }
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

    private func byExercise(_ daySets: [SetEntry]) -> [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets.sorted(by: { $0.date < $1.date }) where !names.contains(s.exercise) {
            names.append(s.exercise)
        }
        return names.map { n in (n, daySets.filter { $0.exercise == n }.sorted { $0.date < $1.date }) }
    }

    private var pastDays: [Date] {
        var seen = Set<Int>()
        var out: [Date] = []
        // `sets` staat aflopend op datum, dus de eerste hit per dag is meteen de juiste.
        for s in sets where seen.insert(dayKey(s.date)).inserted {
            out.append(cal.startOfDay(for: s.date))
            if out.count == 90 { break }
        }
        return out
    }

    private func lastSession(for name: String, _ history: HistoryIndex) -> [SetEntry] {
        let prev = (history.byExercise[name] ?? []).filter { $0.date < startedAt }
        guard let latest = prev.map(\.date).max() else { return [] }
        let key = dayKey(latest)
        return prev.filter { dayKey($0.date) == key }.sorted { $0.date < $1.date }
    }

    private var trainedThisWeek: Int {
        let weekStart = cal.startOfDay(for: .now).addingTimeInterval(-6 * 86_400)
        return Set(sets.filter { $0.date > weekStart }.map { dayKey($0.date) }).count
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
        sets.contains { dayKey($0.date) == dayKey(day) }
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

    /// Dag met minstens één nieuw e1RM-record.
    private func isPRDay(_ day: Date, _ history: HistoryIndex) -> Bool {
        let start = cal.startOfDay(for: day)
        // Per oefening één keer het oude record bepalen i.p.v. per set opnieuw scannen.
        var bestBefore: [String: Double] = [:]
        for s in sets(on: day, history) {
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
    private func lastSessionSummary(_ name: String, _ history: HistoryIndex) -> String? {
        let last = lastSession(for: name, history)
        guard !last.isEmpty else { return nil }
        let bw = history.isBodyweight(name)
        return last.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  ")
    }

    private func restLabel(_ seconds: Int) -> String {
        seconds <= 0 ? "uit" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
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
                  sets: ex.sets.map { .init(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, warmup: $0.warmup, dropset: $0.dropset, failure: $0.failure, seconds: $0.seconds) },
                  originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }, alternatives: alternatives.isEmpty ? nil : alternatives,
           restEndsAt: workoutStatus.restEndsAt,
           workoutNote: workoutNote.isEmpty ? nil : workoutNote)
    }

    /// Na een force-quit: training terugzetten en de Live Activity weer adopteren.
    private func restoreDraft() {
        guard !active,
              let data = UserDefaults.standard.data(forKey: "activeWorkout"),
              let saved = try? JSONDecoder().decode(SavedWorkout.self, from: data) else { return }
        startedAt = saved.startedAt
        workout = saved.exercises.map { ex in
            DraftExercise(name: ex.name, tip: ex.tip,
                          sets: ex.sets.map { DraftSet(kg: $0.kg, reps: $0.reps, done: $0.done, previous: $0.previous, warmup: $0.warmup ?? false, dropset: $0.dropset ?? false, failure: $0.failure ?? false, seconds: $0.seconds ?? 0) },
                          note: ex.note, originalName: ex.originalName, superset: ex.superset, restSeconds: ex.restSeconds)
        }
        alternatives = saved.alternatives ?? [:]
        workoutNote = saved.workoutNote ?? ""
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
            for s in ex.sets { if let e = s.savedEntry, !e.isDeleted { context.delete(e) } }
        }
        withAnimation(.snappy(duration: 0.25)) { workout.removeAll { $0.id == id } }
    }

    private func saveExerciseNotes() {
        let notes = workout
            .map { ($0.name, $0.note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        guard !notes.isEmpty else { return }
        let record = habits.first { cal.isDateInToday($0.date) } ?? {
            let h = DayHabits()
            context.insert(h)
            return h
        }()
        for (name, text) in notes { record.exerciseNotes[name] = text }
    }

    /// Algemene sessie-notitie op de dag bewaren (los van de per-oefening notities).
    private func saveWorkoutNote() {
        let clean = workoutNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let record = habits.first { cal.isDateInToday($0.date) } ?? {
            let h = DayHabits()
            context.insert(h)
            return h
        }()
        record.workoutNote = clean
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
        saveExerciseNotes()
        saveWorkoutNote()
        WorkoutStatus.shared.endWorkout()
        let history = makeHistory()
        // Vergelijk met de vorige sessie die minstens één oefening deelt — niet met een
        // willekeurige vorige dag (anders vergelijk je Legs met Push).
        let names = Set(workout.map(\.name))
        let previousDay = pastDays.first { day in
            !cal.isDateInToday(day) && sets(on: day, history).contains { names.contains($0.exercise) }
        }
        let previousVolume = previousDay.map { day in
            Int(sets(on: day, history).map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight, bodyweightExercise: history.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
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
            workoutNote = ""
        }
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

    /// Actieve training blijft een List: swipe-to-delete op sets bestaat daarbuiten
    /// niet, en tijdens het loggen wil je juist een dichte lijst.
    @ViewBuilder private func screen(_ history: HistoryIndex, _ pastNotes: [DayHabits]) -> some View {
        if active {
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

    @ViewBuilder private var content: some View {
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
        .navigationBarTitleDisplayMode(active ? .inline : .large)
        .toolbar(active ? .automatic : .hidden, for: .navigationBar) // idle heeft z'n eigen titel
        .scrollDismissesKeyboard(.interactively)
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
            Button("Verwijder \(dayToDelete.map { sets(on: $0, history).count } ?? 0) sets", role: .destructive) {
                if let day = dayToDelete {
                    for s in sets(on: day, history) { context.delete(s) }
                }
                dayToDelete = nil
            }
            Button("Annuleer", role: .cancel) { dayToDelete = nil }
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
            RoutineEditorView(routine: routine) { r in
                editingRoutine = nil
                startWorkout(with: r.exercises, alternatives: r.alternatives, targets: r.targets,
                             supersets: r.supersets, restByExercise: r.restByExercise)
            }
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

    // MARK: - Idle: kaarten i.p.v. een List, zodat de tab niet leest als Instellingen

    /// Eén weekstrip die zowel toont wát je deed als wát er gepland staat. Stond eerder
    /// twee keer op het scherm: "Deze week" (bolletjes) plus zeven Form-rijen met de planning.
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

    /// Eén dag: gedaan (vol), gepland (routine-kleur), of leeg. Tik = routine koppelen.
    private func weekDay(_ day: Date, _ history: HistoryIndex) -> some View {
        let did = !sets(on: day, history).isEmpty
        let weekday = cal.component(.weekday, from: day)
        let planned = profile.plannedRoutine(weekday: weekday)
        let routine = routines.first { $0.name == planned }
        let tint = routine.map { routineColor($0, history) } ?? .green
        let isToday = cal.isDateInToday(day)

        return Menu {
            Button("Rustdag") { assignRoutine(nil, to: weekday) }
            Divider()
            ForEach(routines) { r in
                Button {
                    assignRoutine(r.name, to: weekday)
                } label: {
                    if planned == r.name { Label(r.name, systemImage: "checkmark") } else { Text(r.name) }
                }
            }
        } label: {
            VStack(spacing: 5) {
                // Color.primary i.p.v. .primary: binnen een Menu-label worden de
                // hiërarchische stijlen getint met het accent, en dan wordt alles groen.
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.primary : Color.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous)
                        .fill(did ? AnyShapeStyle(tint) : AnyShapeStyle(.builtTint(planned == nil ? .gray : tint)))
                        .frame(height: 46)
                    if did {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    } else if let planned {
                        Text(planned.prefix(2).uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(tint)
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
            .contentShape(Rectangle())
        }
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month()))
        .accessibilityValue(did ? "Getraind" : (planned.map { "Gepland: \($0)" } ?? "Rustdag"))
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

    private func plannedCard(_ planned: Routine, _ history: HistoryIndex) -> some View {
        let tint = routineColor(planned, history)
        return Button {
            startWorkout(with: planned.exercises, alternatives: planned.alternatives, targets: planned.targets,
                         supersets: planned.supersets, restByExercise: planned.restByExercise)
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous)
                    .fill(.builtTint(tint))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: routineIcon(planned, history))
                            .font(.title3)
                            .foregroundStyle(tint)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VANDAAG GEPLAND")
                        .font(.caption2.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(planned.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.green, in: Circle())
            }
            .builtCard()
        }
        .buttonStyle(PressableStyle(scale: 0.985))
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
                    if !routine.exercises.isEmpty {
                        Button("Start meteen", systemImage: "play.fill") {
                            startWorkout(with: routine.exercises, alternatives: routine.alternatives,
                                         targets: routine.targets, supersets: routine.supersets,
                                         restByExercise: routine.restByExercise)
                        }
                    }
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

    private func historyCard(_ day: Date, _ history: HistoryIndex) -> some View {
        let daySets = sets(on: day, history)
        let vol = Int(daySets.map { $0.weightKg * Double($0.reps) }.reduce(0, +))
        return NavigationLink {
            SessionDetailView(day: day)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isPRDay(day, history) {
                        Text("🏆").font(.caption).accessibilityLabel("Persoonlijk record")
                    }
                    Spacer()
                    Text("\(vol) kg")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(byExercise(daySets), id: \.name) { group in
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
            Button("Verwijder deze dag", systemImage: "trash", role: .destructive) { dayToDelete = day }
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

        if let planned = todayPlanned, !trained(on: cal.startOfDay(for: .now)) {
            plannedCard(planned, history)
        }

        weekCard(history)
        if !routines.isEmpty {
            BuiltFootnote("Tik op een dag om er een routine aan te koppelen.")
        }

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
        if pastDays.isEmpty {
            ContentUnavailableView("Nog geen trainingen", systemImage: "clock.arrow.circlepath",
                                   description: Text("Je eerste training verschijnt hier — met volume, oefeningen en records."))
                .builtCard()
        }
        ForEach(pastDays, id: \.self) { day in
            historyCard(day, history)
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
                    let volume = volume(history)
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
            exerciseSection($ex, history, pastNotes)
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

        Section("Notitie voor deze training") {
            TextField("Bijv. voelde sterk, korte sessie", text: $workoutNote, axis: .vertical)
                .lineLimit(1...6)
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
    private func updateActivity(exercise name: String, currentKg: Double, _ history: HistoryIndex) {
        guard let ex = workout.first(where: { $0.name == name }) else { return }
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
                Text(bodyweight ? "+KG" : "KG").frame(width: 56)
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
            setRow($set, number: numbers[set.id] ?? 0, exercise: ex.name,
                   bodyweight: bodyweight, cardio: cardio, history: history,
                   duplicate: { duplicateSet(exercise: ex.id, set: set.id) })
        }
        .onDelete { offsets in
            for i in offsets {
                if let e = ex.sets[i].savedEntry, !e.isDeleted { context.delete(e) }
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
            Label("Set toevoegen", systemImage: "plus")
                .font(.footnote.bold())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
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
                    Text(ex.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
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

    private func setRow(_ set: Binding<DraftSet>, number: Int, exercise: String, bodyweight: Bool,
                        cardio: Bool, history: HistoryIndex, duplicate: @escaping () -> Void) -> some View {
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
            Text(set.wrappedValue.previous ?? "—")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
                .opacity(set.wrappedValue.done ? 0.55 : 1)
            if cardio {
                NumericField(value: Binding(get: { Double(set.wrappedValue.seconds / 60) },
                                            set: { set.wrappedValue.seconds = Int(min($0.rounded(), 600)) * 60 }),
                             decimal: false, placeholder: "min",
                             focus: $focusedSet, id: set.wrappedValue.id,
                             disabled: set.wrappedValue.done)
                    .frame(width: 56)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                    .opacity(set.wrappedValue.done ? 0.55 : 1)
                Text("min").font(.footnote).foregroundStyle(.secondary)
            } else {
                NumericField(value: set.kg, decimal: true, placeholder: bodyweight ? "+kg" : "kg",
                             focus: $focusedSet, id: set.wrappedValue.id,
                             disabled: set.wrappedValue.done)
                    .frame(width: 56)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                    .opacity(set.wrappedValue.done ? 0.55 : 1)
                NumericField(value: Binding(get: { Double(set.wrappedValue.reps) },
                                            set: { set.wrappedValue.reps = Int(min($0.rounded(), 9999)) }),
                             decimal: false, placeholder: "reps",
                             focus: $focusedSet, id: nil,
                             disabled: set.wrappedValue.done)
                    .frame(width: 48)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                    .opacity(set.wrappedValue.done ? 0.55 : 1)
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    set.wrappedValue.done.toggle()
                    if set.wrappedValue.done {
                        if !set.wrappedValue.warmup {
                            let e = SetEntry(exercise: exercise, weightKg: set.wrappedValue.kg, reps: set.wrappedValue.reps,
                                             dropset: set.wrappedValue.dropset, failure: set.wrappedValue.failure,
                                             seconds: set.wrappedValue.seconds)
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
                        // Na een herstelde training is savedEntry weg — zoek 'm terug
                        let e = set.wrappedValue.savedEntry ?? sets.first {
                            $0.exercise == exercise && $0.date >= startedAt
                                && $0.weightKg == set.wrappedValue.kg && $0.reps == set.wrappedValue.reps
                                && $0.seconds == set.wrappedValue.seconds
                        }
                        if let e, !e.isDeleted { context.delete(e) }
                        set.wrappedValue.savedEntry = nil
                    }
                    updateActivity(exercise: exercise, currentKg: set.wrappedValue.kg, history)
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
                    StatTile(value: "\(summary.minutes)", label: "minuten")
                    StatTile(value: "\(summary.volume)", label: "kg volume")
                    StatTile(value: "\(summary.sets)", label: "sets")
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
                    .background(.builtTint(.yellow), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
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
            HStack(spacing: 12) {
                ShareLink(item: summary.shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(height: 22)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                } label: {
                    Text("Klaar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .builtBottomAction()
            .background(.regularMaterial)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { bounced = true }
        .sensoryFeedback(.success, trigger: bounced)
    }

}

/// Overzicht van één gedane training: duur, volume, verbeteringen — en bewerkbaar
/// (kg/reps aanpassen, set of oefening verwijderen).
struct SessionDetailView: View {
    let day: Date
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allHabits: [DayHabits]
    @Query private var exercises: [Exercise]
    @Query(sort: \WeightEntry.date) private var allWeights: [WeightEntry]
    @FocusState private var focused: UUID?

    /// Lichaamsgewicht rond een dag, voor het meetellen van bodyweight-oefeningen.
    private func bodyWeight(on d: Date) -> Double {
        (allWeights.last { $0.date <= d } ?? allWeights.last)?.kg ?? 0
    }

    private var cal: Calendar { .current }
    private var daySets: [SetEntry] {
        allSets.filter { dayKey($0.date) == dayKey(day) }.sorted { $0.date < $1.date }
    }

    private var habitsRecord: DayHabits? { allHabits.first { dayKey($0.date) == dayKey(day) } }

    private func record() -> DayHabits {
        if let h = habitsRecord { return h }
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let h = DayHabits(date: noon)
        context.insert(h)
        return h
    }

    private var workoutNoteBinding: Binding<String> {
        Binding(get: { habitsRecord?.workoutNote ?? "" },
                set: { record().workoutNote = $0 })
    }

    private var byExercise: [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets where !names.contains(s.exercise) { names.append(s.exercise) }
        return names.map { n in (n, daySets.filter { $0.exercise == n }) }
    }

    private var volume: Int {
        Int(daySets.map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: day), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
    }

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
        let pv = Int(allSets.filter { dayKey($0.date) == dayKey(prev) }
            .map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: prev), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
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
    private func minutes(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { Double(set.seconds / 60) }, set: { set.seconds = Int(min($0.rounded(), 600)) * 60 })
    }

    private var shareText: String {
        workoutShareText(title: "Training van \(day.formatted(.dateTime.weekday(.wide).day().month()))",
                         duration: durationText, volume: volume, sets: daySets.count,
                         lines: byExercise.map { group in
                             let bw = exercises.isBodyweight(group.name)
                             return "\(group.name): " + group.sets.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  ")
                         },
                         prs: prs)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    StatTile(value: durationText, label: "duur")
                    StatTile(value: "\(volume)", label: "kg volume")
                    StatTile(value: "\(daySets.count)", label: "sets")
                }
                if let d = volumeDelta {
                    Text("\(d >= 0 ? "+" : "")\(d) kg volume t.o.v. je vorige training")
                        .font(.footnote)
                        .foregroundStyle(d >= 0 ? .green : .secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section("Notitie") {
                TextField("Notitie over deze training", text: workoutNoteBinding, axis: .vertical)
                    .lineLimit(1...6)
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
                            if exercises.isCardio(group.name) {
                                NumericField(value: minutes(set), decimal: false, placeholder: "min",
                                             focus: $focused, id: nil, disabled: false)
                                    .frame(width: 64)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text("min").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                NumericField(value: kg(set), decimal: true, placeholder: exercises.isBodyweight(group.name) ? "+kg" : "kg",
                                             focus: $focused, id: nil, disabled: false)
                                    .frame(width: 64)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text(exercises.isBodyweight(group.name) ? "+kg" : "kg").font(.footnote).foregroundStyle(.secondary)
                                NumericField(value: reps(set), decimal: false, placeholder: "reps",
                                             focus: $focused, id: nil, disabled: false)
                                    .frame(width: 52)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text("reps").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(group.sets[i]) }
                    }
                    Button {
                        if let last = group.sets.last {
                            context.insert(SetEntry(date: last.date.addingTimeInterval(1),
                                                    exercise: group.name, weightKg: last.weightKg, reps: last.reps,
                                                    seconds: last.seconds))
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
        .toolbar {
            ShareLink(item: shareText)
            EditButton()
        }
    }

}

/// Preview van een routine: zie wat je gaat doen, pas het aan, of start hem meteen.
struct RoutineEditorView: View {
    @Bindable var routine: Routine
    /// nil = alleen bewerken (bijv. vanuit onboarding); anders verschijnt de startknop.
    var onStart: ((Routine) -> Void)?
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query private var exercises: [Exercise]
    @State private var showPicker = false

    private func subtitle(for name: String) -> String {
        var parts: [String] = []
        if let t = routine.targets[name], t.count > 1 {
            parts.append(exercises.isCardio(name) ? "\(t[1]) min" : "\(t[0]) × \(t[1])")
        }
        if let group = routine.supersets[name] { parts.append("Superset \(group)") }
        let alts = routine.alternatives[name] ?? []
        if !alts.isEmpty { parts.append("Alt: \(alts.joined(separator: ", "))") }
        return parts.joined(separator: "  ·  ")
    }

    /// Wat je in totaal gaat doen — de kern van de preview.
    private var totals: String {
        let count = routine.exercises.count
        let setCount = routine.exercises.reduce(0) { $0 + (routine.targets[$1]?.first ?? 3) }
        return "\(count) oefening\(count == 1 ? "" : "en") · \(setCount) sets"
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
                Text(routine.exercises.isEmpty ? "Oefeningen" : "\(totals) — sleep om de volgorde te bepalen")
            } footer: {
                Text("Tik op een oefening voor sets × reps en alternatieven. Tijdens de training wissel je via het ⋯-menu als een toestel bezet is.")
            }
        }
        // Volgorde telt: de startknop eerst, dan de tab-bar-ruimte eronder.
        .safeAreaInset(edge: .bottom) {
            if let onStart, !routine.exercises.isEmpty {
                Button {
                    onStart(routine)
                } label: {
                    Label("Start deze training", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .builtBottomAction()
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
    @Query private var exercises: [Exercise]
    @State private var showAltPicker = false

    private var cardio: Bool { exercises.isCardio(exercise) }
    private var target: [Int] { routine.targets[exercise] ?? (cardio ? [1, 20] : [3, 8]) }
    private func setTarget(sets s: Int, reps r: Int) { routine.targets[exercise] = [s, r] }

    var body: some View {
        List {
            Section {
                if cardio {
                    Stepper("Minuten: \(target[1])", value: Binding(
                        get: { target[1] },
                        set: { setTarget(sets: 1, reps: $0) }
                    ), in: 1...180, step: 5)
                } else {
                    Stepper("Sets: \(target[0])", value: Binding(
                        get: { target[0] },
                        set: { setTarget(sets: $0, reps: target[1]) }
                    ), in: 1...10)
                    Stepper("Reps: \(target[1])", value: Binding(
                        get: { target[1] },
                        set: { setTarget(sets: target[0], reps: $0) }
                    ), in: 1...30)
                }
            } header: {
                Text("Doel")
            } footer: {
                Text(cardio ? "Bij het starten van de routine staat \(target[1]) minuten klaar."
                            : "Bij het starten van de routine krijg je \(target[0]) sets van \(target[1]) reps voorgezet.")
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
