import ActivityKit
import Foundation
import SwiftData
import Observation

/// Gedeelde trainingsstatus: andere tabs tonen de "bezig"-pill, en de rust-timer
/// leeft hier zodat hij overal zichtbaar blijft.
@MainActor
@Observable
final class WorkoutStatus {
    static let shared = WorkoutStatus()
    var startedAt: Date?
    var restStartedAt: Date?
    var restEndsAt: Date?
    var restFired = false
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<WorkoutActivity>?
    @ObservationIgnored private var context = WorkoutActivity.ContentState()

    func startWorkout(at date: Date = .now) {
        startedAt = date
        // Live Activity: training + rust zichtbaar in Dynamic Island en op het lockscreen
        activity = try? Activity.request(attributes: WorkoutActivity(startedAt: date),
                                         content: .init(state: .init(), staleDate: nil))
    }

    /// Herstart na een force-quit: neem de nog-lopende Live Activity over i.p.v. een nieuwe te maken.
    func resumeWorkout(at date: Date) {
        startedAt = date
        activity = Activity<WorkoutActivity>.activities.first
        if activity == nil {
            activity = try? Activity.request(attributes: WorkoutActivity(startedAt: date),
                                             content: .init(state: .init(), staleDate: nil))
        }
    }

    func endWorkout() {
        startedAt = nil
        context = .init()
        stopRest()
        let activity = self.activity
        self.activity = nil
        Task { await activity?.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ruimt een activity op die is blijven hangen na een herstart — behalve als er
    /// een opgeslagen training op herstel wacht; die adopteert hem via resumeWorkout.
    func cleanupStaleActivities() {
        guard startedAt == nil, UserDefaults.standard.data(forKey: "activeWorkout") == nil else { return }
        Task {
            for stale in Activity<WorkoutActivity>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Waar je mee bezig bent, voor het eiland en lockscreen — gezet bij elke afgevinkte set.
    func updateContext(exercise: String?, setsDone: Int, setsTotal: Int, tip: String?) {
        context.exercise = exercise
        context.setsDone = setsDone
        context.setsTotal = setsTotal
        context.tip = tip
        pushActivity()
    }

    private func pushActivity() {
        guard let activity else { return }
        var state = context
        state.restStartedAt = restStartedAt
        state.restEndsAt = restEndsAt
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func startRest(seconds: Int) {
        guard seconds > 0 else { return }
        startRest(until: .now.addingTimeInterval(Double(seconds)))
    }

    func startRest(until end: Date) {
        restStartedAt = .now
        schedule(end: end)
    }

    /// +15s: einde schuift op, start blijft — de progressiebalk rekt mee i.p.v. te resetten.
    func extendRest(by seconds: Double) {
        guard let end = restEndsAt else { return }
        schedule(end: end.addingTimeInterval(seconds))
    }

    private func schedule(end: Date) {
        restEndsAt = end
        Notifier.shared.scheduleRest(at: end) // lockscreen-melding als de app dicht is
        restTask?.cancel()
        restTask = Task { @MainActor in
            let interval = end.timeIntervalSinceNow
            guard interval > 0 else { return }
            try? await Task.sleep(for: .seconds(interval))
            if !Task.isCancelled {
                self.restFired.toggle()
                self.restEndsAt = nil
                self.pushActivity()
            }
        }
        pushActivity()
    }

    func stopRest() {
        restTask?.cancel()
        restEndsAt = nil
        Notifier.shared.cancelRest()
        pushActivity()
    }

    /// Neemt een +15s/Skip over die via de Live Activity-knop is gedaan terwijl de app sliep.
    func reconcileRestOverride() {
        let defaults = UserDefaults(suiteName: "group.com.jordiklavers.Built")
        guard let defaults, defaults.object(forKey: "restOverride") != nil else { return }
        let value = defaults.double(forKey: "restOverride")
        defaults.removeObject(forKey: "restOverride")
        if value == 0 {
            stopRest()
        } else {
            let end = Date(timeIntervalSinceReferenceDate: value)
            if end > .now { schedule(end: end) } else { stopRest() }
        }
    }
}

@Model
final class Profile {
    var name: String
    var age: Int
    var heightCm: Int
    var startWeight: Double
    var goalWeight: Double
    var startDate: Date
    var goalDate: Date
    var trainingsPerWeek: Int
    var tracksCreatine: Bool = true
    var tracksSleep: Bool = true
    /// Eten bijhouden. Uit = eiwit telt niet mee voor score/streak en verdwijnt van het dashboard.
    var tracksFood: Bool = true
    /// Handmatig calorie-doel; 0 = automatisch berekenen uit lengte/gewicht/doel.
    var kcalTarget: Int = 0
    /// Geplande trainingsdagen (Calendar weekday 1=zo…7=za). Leeg = geen vaste dagen.
    var trainingDays: [Int] = []
    /// Weekplanning: weekday-string ("2"=ma) → routine-naam. Bepaalt welke routine welke dag.
    var schedule: [String: String] = [:]

    init(name: String, age: Int, heightCm: Int, startWeight: Double, goalWeight: Double, goalDate: Date, trainingsPerWeek: Int) {
        self.name = name
        self.age = age
        self.heightCm = heightCm
        self.startWeight = startWeight
        self.goalWeight = goalWeight
        self.startDate = .now
        self.goalDate = goalDate
        self.trainingsPerWeek = trainingsPerWeek
    }

    // ponytail: 1,6 g eiwit per kg doelgewicht — simpele regel, goed genoeg
    var proteinTarget: Int { Int((goalWeight * 1.6).rounded()) }
    var totalWeeks: Double { max(goalDate.timeIntervalSince(startDate) / 604_800, 1) }
    var weeklyRate: Double { (goalWeight - startWeight) / totalWeeks }
    var daysIn: Int { max(Calendar.current.dateComponents([.day], from: startDate, to: .now).day ?? 0, 0) }
    var expectedGain: Double { weeklyRate * Double(daysIn) / 7 }

    /// Mifflin-St Jeor (man) × activiteit op basis van trainingsfrequentie,
    /// plus het overschot dat bij je gewenste tempo hoort (~7700 kcal per kg).
    func autoKcalTarget(currentWeight: Double) -> Int {
        let bmr = 10 * currentWeight + 6.25 * Double(heightCm) - 5 * Double(age) + 5
        let activity = trainingsPerWeek >= 5 ? 1.725 : trainingsPerWeek >= 3 ? 1.55 : 1.375
        let surplus = weeklyRate * 7700 / 7
        return max(Int((bmr * activity + surplus).rounded()), 1200)
    }

    func kcalTargetEffective(currentWeight: Double) -> Int {
        kcalTarget > 0 ? kcalTarget : autoKcalTarget(currentWeight: currentWeight)
    }

    /// Geplande routine voor een weekdag (1=zo…7=za), nil = geen.
    func plannedRoutine(weekday: Int) -> String? {
        let name = schedule[String(weekday)]
        return (name?.isEmpty ?? true) ? nil : name
    }
}

@Model
final class WeightEntry {
    var date: Date
    var kg: Double
    var scale: String = ""
    init(date: Date = .now, kg: Double, scale: String = "") {
        self.date = date
        self.kg = kg
        self.scale = scale
    }
}

@Model
final class Scale {
    var name: String
    init(name: String) {
        self.name = name
    }
}

@Model
final class CustomHabit {
    var name: String
    var createdAt: Date
    init(name: String) {
        self.name = name
        self.createdAt = .now
    }
}

@Model
final class HabitLog {
    var name: String
    var date: Date
    init(name: String, date: Date = .now) {
        self.name = name
        self.date = date
    }
}

@Model
final class PhotoEntry {
    var date: Date
    var angle: String // "front" | "side" | "back"
    var fileName: String
    init(date: Date = .now, angle: String, fileName: String) {
        self.date = date
        self.angle = angle
        self.fileName = fileName
    }

    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("ProgressPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var fileURL: URL { Self.directory.appendingPathComponent(fileName) }
}

/// Geschat 1RM via de Epley-formule.
func epley(_ weight: Double, _ reps: Int) -> Double {
    reps <= 1 ? weight : weight * (1 + Double(reps) / 30)
}

/// Set-notatie voor overzichten. Cardio toont de duur ("25 min"); bodyweight zonder
/// extra gewicht alleen reps (bijv. "×8"); met extra gewicht "+5×8"; anders "40×8".
func setNotation(kg: Double, reps: Int, bodyweight: Bool, seconds: Int = 0) -> String {
    if seconds > 0 { return "\(seconds / 60) min" }
    guard bodyweight else { return "\(kg.kgText)×\(reps)" }
    return kg > 0 ? "+\(kg.kgText)×\(reps)" : "×\(reps)"
}

/// Platte tekst van een afgeronde training om te delen — werkt in elke app.
func workoutShareText(title: String, duration: String, volume: Int, sets: Int,
                      lines: [String], prs: [(exercise: String, new: Double, old: Double)]) -> String {
    var out = ["💪 \(title)", "\(duration) · \(volume) kg volume · \(sets) sets", ""]
    out += lines
    if !prs.isEmpty {
        out.append("")
        out += prs.map { "🏆 \($0.exercise): e1RM \($0.new.kgText) kg (was \($0.old.kgText))" }
    }
    return out.joined(separator: "\n")
}

/// Effectieve last voor volume/spierkaart: bodyweight-oefeningen tellen mee met
/// lichaamsgewicht + eventueel extra gewicht, zodat ze niet op 0 uitkomen.
func liftLoad(kg: Double, bodyweight: Double, bodyweightExercise: Bool) -> Double {
    bodyweightExercise ? max(bodyweight, 0) + kg : kg
}

/// Schijven per kant voor een barbell-gewicht, greedy vanaf de zwaarste schijf.
/// nil als het gewicht de stang niet haalt. Reststukje < kleinste schijf wordt genegeerd.
func platesPerSide(total: Double, bar: Double = 20) -> [Double]? {
    guard total >= bar else { return nil }
    var perSide = (total - bar) / 2
    var out: [Double] = []
    for p in [25.0, 20, 15, 10, 5, 2.5, 1.25] {
        while perSide >= p - 0.01 { out.append(p); perSide -= p }
    }
    return out
}

@Model
final class ProteinEntry {
    var date: Date
    var grams: Int
    var label: String
    var kcal: Int = 0
    var carbs: Int = 0
    var fat: Int = 0
    var meal: String = "" // "breakfast" | "lunch" | "dinner" | "snack"; leeg = raden op tijdstip
    init(date: Date = .now, grams: Int, label: String, kcal: Int = 0, carbs: Int = 0, fat: Int = 0, meal: String = "") {
        self.date = date
        self.grams = grams
        self.label = label
        self.kcal = kcal
        self.carbs = carbs
        self.fat = fat
        self.meal = meal
    }

    static func guessMeal(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: "breakfast"
        case 11..<15: "lunch"
        case 17..<22: "dinner"
        default: "snack"
        }
    }

    /// Effectieve maaltijd: expliciet gekozen, anders geraden op tijdstip.
    var mealKey: String { meal.isEmpty ? Self.guessMeal(for: date) : meal }
}

/// Product uit de scanner of zoekfunctie; voedingswaarden per 100 g.
@Model
final class FoodProduct {
    var name: String
    var brand: String = ""
    var barcode: String = ""
    var protein100: Double
    var kcal100: Double
    var carbs100: Double = 0
    var fat100: Double = 0
    var favorite: Bool = false
    var imageURL: String = ""
    /// Eigen eenheid: "1 ei" = servingName "ei", servingGrams 60. 0 = alleen gram.
    var servingGrams: Double = 0
    var servingName: String = ""
    var createdAt: Date = Date.now
    var lastUsed: Date = Date.now

    init(name: String, brand: String = "", barcode: String = "",
         protein100: Double, kcal100: Double, carbs100: Double = 0, fat100: Double = 0) {
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.protein100 = protein100
        self.kcal100 = kcal100
        self.carbs100 = carbs100
        self.fat100 = fat100
    }
}

struct Ingredient: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var protein: Int
    var kcal: Int
}

/// Eén journal-notitie met eigen tijdstip; meerdere per dag hangen als array aan DayHabits.
struct JournalNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var createdAt: Date = .now
}

@Model
final class Meal {
    var name: String
    var protein: Int
    var kcal: Int
    var createdAt: Date
    var servings: Double = 1
    var ingredients: [Ingredient] = []
    var favorite: Bool = false
    init(name: String, protein: Int, kcal: Int) {
        self.name = name
        self.protein = protein
        self.kcal = kcal
        self.createdAt = .now
    }

    // ponytail: geen ingrediënten = simpele maaltijd, dan gelden de directe waarden
    var totalProtein: Int { ingredients.isEmpty ? protein : ingredients.map(\.protein).reduce(0, +) }
    var totalKcal: Int { ingredients.isEmpty ? kcal : ingredients.map(\.kcal).reduce(0, +) }
    var proteinPerServing: Int { ingredients.isEmpty ? protein : Int((Double(totalProtein) / max(servings, 0.5)).rounded()) }
    var kcalPerServing: Int { ingredients.isEmpty ? kcal : Int((Double(totalKcal) / max(servings, 0.5)).rounded()) }
}

@Model
final class SetEntry {
    var date: Date
    var exercise: String
    var weightKg: Double
    var reps: Int
    var dropset: Bool = false
    var failure: Bool = false
    /// Duur voor cardio-oefeningen in seconden; 0 = gewone krachtset.
    var seconds: Int = 0
    init(date: Date = .now, exercise: String, weightKg: Double, reps: Int,
         dropset: Bool = false, failure: Bool = false, seconds: Int = 0) {
        self.date = date
        self.exercise = exercise
        self.weightKg = weightKg
        self.reps = reps
        self.dropset = dropset
        self.failure = failure
        self.seconds = seconds
    }
}

@Model
final class Routine {
    var name: String
    var exercises: [String]
    var createdAt: Date
    /// Vervangers per oefening, voor als een toestel bezet of stuk is.
    var alternatives: [String: [String]] = [:]
    /// Doel per oefening als [sets, reps], bijv. "3× dumbbell press" = [3, 10].
    var targets: [String: [Int]] = [:]
    /// Superset-groep per oefening (naam → "A"/"B"/…). Zelfde groep = weinig rust ertussen.
    var supersets: [String: String] = [:]
    /// Rusttijd per oefening in seconden; ontbreekt = de globale instelling.
    var restByExercise: [String: Int] = [:]
    init(name: String, exercises: [String] = []) {
        self.name = name
        self.exercises = exercises
        self.createdAt = .now
    }
}

@Model
final class DayHabits {
    var date: Date
    var creatine: Bool
    var sleptEnough: Bool
    var note: String = ""
    var bedTime: Date?
    var wakeTime: Date?
    var sleepQuality: Int = 0 // 0 = niet ingevuld, 1-3 = slecht/oké/goed
    /// Dag-check-in, allemaal 0 = niet ingevuld, 1–5 = laag…hoog.
    var energy: Int = 0
    var mood: Int = 0
    var soreness: Int = 0
    var stress: Int = 0
    /// Journal: meerdere getimede notities per dag.
    var journal: [JournalNote] = []
    /// Algemene notitie bij de training van die dag (los van de per-oefening notities).
    var workoutNote: String = ""
    init(date: Date = .now, creatine: Bool = false, sleptEnough: Bool = false) {
        self.date = date
        self.creatine = creatine
        self.sleptEnough = sleptEnough
    }

    var sleepHours: Double? {
        guard let b = bedTime, let w = wakeTime else { return nil }
        var h = w.timeIntervalSince(b) / 3600
        if h < 0 { h += 24 }
        return h
    }

    /// Dag-check-in ingevuld? Eén van de vier is genoeg — anders voelt het als huiswerk.
    var checkedIn: Bool { energy > 0 || mood > 0 || soreness > 0 || stress > 0 }
}

// MARK: - Dag-index
//
// `Calendar.isDate(_:inSameDayAs:)` kost ~3 µs per aanroep. In een `filter` over een
// tabel met duizenden rijen, en dat per dag, loopt dat op tot seconden per render.
// Onderstaande twee dingen vervangen dat patroon: een goedkope dag-sleutel, en een
// index die je één keer per render bouwt en daarna O(1) bevraagt.

/// Lokale kalenderdag als geheel getal (opeenvolgende dagen = opeenvolgende getallen).
/// ~27× goedkoper dan `Calendar.startOfDay` (114 ns vs 3,1 µs) en over ruim een miljoen
/// paren rond DST-overgangen identiek aan `Calendar.isDate(_:inSameDayAs:)`.
@inline(__always) func dayKey(_ date: Date) -> Int {
    let offset = Double(TimeZone.autoupdatingCurrent.secondsFromGMT(for: date))
    return Int(((date.timeIntervalSinceReferenceDate + offset) / 86_400).rounded(.down))
}

/// Alle "wat gebeurde er op dag X?"-vragen, één keer voorbewerkt.
///
/// Bouwen kost één pass per tabel (~0,2 ms per 1.000 rijen); daarna is elke vraag O(1).
/// Bouw 'm bovenaan `body` in een `let` en geef 'm door — niet als computed property,
/// want die zou bij elke aanroep opnieuw opbouwen.
///
/// `weights` moet oplopend op datum staan: bij meerdere wegingen op één dag wint de laatste.
struct DayIndex {
    private var proteinG: [Int: Int] = [:]
    private var proteinKcal: [Int: Int] = [:]
    private var dayVolume: [Int: Double] = [:]
    private var trainedDays: Set<Int> = []
    private var weightByDay: [Int: Double] = [:]
    private var habitByDay: [Int: DayHabits] = [:]
    private var logsByDay: [Int: Set<String>] = [:]

    init(proteins: [ProteinEntry] = [], weights: [WeightEntry] = [], sets: [SetEntry] = [],
         habits: [DayHabits] = [], habitLogs: [HabitLog] = []) {
        for p in proteins {
            let k = dayKey(p.date)
            proteinG[k, default: 0] += p.grams
            proteinKcal[k, default: 0] += p.kcal
        }
        for w in weights { weightByDay[dayKey(w.date)] = w.kg }
        for s in sets {
            let k = dayKey(s.date)
            trainedDays.insert(k)
            dayVolume[k, default: 0] += s.weightKg * Double(s.reps)
        }
        for h in habits { habitByDay[dayKey(h.date)] = h }
        for l in habitLogs { logsByDay[dayKey(l.date), default: []].insert(l.name) }
    }

    func protein(_ day: Date) -> Int { proteinG[dayKey(day)] ?? 0 }
    func kcal(_ day: Date) -> Int { proteinKcal[dayKey(day)] ?? 0 }
    func volume(_ day: Date) -> Double { dayVolume[dayKey(day)] ?? 0 }
    func trained(_ day: Date) -> Bool { trainedDays.contains(dayKey(day)) }
    func weighed(_ day: Date) -> Bool { weightByDay[dayKey(day)] != nil }
    func weight(_ day: Date) -> Double? { weightByDay[dayKey(day)] }
    func habits(_ day: Date) -> DayHabits? { habitByDay[dayKey(day)] }
    func logged(_ name: String, on day: Date) -> Bool { logsByDay[dayKey(day)]?.contains(name) ?? false }
}

/// Aaneengesloten dagen tot vandaag waarop `done` geldt; vandaag mag nog open staan.
/// ponytail: zelfde vorm als DayCheck.streak, maar voor één losse habit.
func habitStreak(_ done: (Date) -> Bool) -> Int {
    let cal = Calendar.current
    var count = 0
    for n in 0..<365 {
        guard let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: .now)) else { break }
        if done(day) { count += 1 }
        else if n == 0 { continue } // vandaag mag nog open staan
        else { break }
    }
    return count
}

extension Array where Element == WeightEntry {
    /// Gemiddeld gewicht binnen een venster van dagen terug, bv. 0..<7 = afgelopen week.
    func average(daysBack range: Range<Int>) -> Double? {
        let today = dayKey(.now)
        let slice = filter { range.contains(today - dayKey($0.date)) }
        guard !slice.isEmpty else { return nil }
        return slice.map(\.kg).reduce(0, +) / Double(slice.count)
    }

    /// 7-daags gemiddelde nu min 7-daags gemiddelde vorige week = kg/week.
    var trendPerWeek: Double? {
        guard let recent = average(daysBack: 0..<7), let prev = average(daysBack: 7..<14) else { return nil }
        return recent - prev
    }
}

enum DayCheck {
    /// Perfecte dag = de dagelijkse factoren die de gebruiker bijhoudt.
    /// Met geplande trainingsdagen telt training/rustdag-volgens-plan mee (North Star).
    static func perfect(_ day: Date, index: DayIndex,
                        target: Int, requireCreatine: Bool = true, requireSleep: Bool = true,
                        trainingDays: [Int] = [], requireFood: Bool = true) -> Bool {
        let proteinDone = !requireFood || index.protein(day) >= target
        let weighed = index.weighed(day)
        let h = index.habits(day)
        let creatineOK = !requireCreatine || h?.creatine == true
        let sleepOK = !requireSleep || h?.sleptEnough == true
        var trainingOK = true
        if trainingDays.contains(Calendar.current.component(.weekday, from: day)) {
            trainingOK = index.trained(day)
        }
        return proteinDone && weighed && creatineOK && sleepOK && trainingOK
    }

    static func streak(index: DayIndex,
                       target: Int, requireCreatine: Bool = true, requireSleep: Bool = true,
                       trainingDays: [Int] = [], requireFood: Bool = true) -> Int {
        let cal = Calendar.current
        var count = 0
        for n in 0..<365 {
            guard let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: .now)) else { break }
            if perfect(day, index: index, target: target,
                       requireCreatine: requireCreatine, requireSleep: requireSleep,
                       trainingDays: trainingDays, requireFood: requireFood) { count += 1 }
            else if n == 0 { continue } // vandaag mag nog open staan
            else { break }
        }
        return count
    }
}

extension Array where Element == ProteinEntry {
    /// Meest gelogde items eerst, extra gewicht voor items die je vaak rond dit uur logt.
    func suggestions(limit: Int = 4) -> [(key: String, label: String, grams: Int, kcal: Int)] {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: .now)
        var scores: [String: Double] = [:]
        var info: [String: (label: String, grams: Int, kcal: Int)] = [:]
        for e in self {
            let key = "\(e.label)|\(e.grams)"
            let h = cal.component(.hour, from: e.date)
            let dist = Swift.min(abs(h - hour), 24 - abs(h - hour))
            scores[key, default: 0] += dist <= 2 ? 2 : 1
            info[key] = (e.label, e.grams, e.kcal)
        }
        var out = scores.sorted { $0.value > $1.value }.compactMap { key, _ in
            info[key].map { (key: key, label: $0.label, grams: $0.grams, kcal: $0.kcal) }
        }
        // ponytail: fallback zolang er weinig eigen historie is
        for (label, grams) in [("Whey shake", 25), ("Kwark 500 g", 60), ("Kip maaltijd", 40)]
        where !out.contains(where: { $0.label == label }) {
            out.append((key: "\(label)|\(grams)", label: label, grams: grams, kcal: 0))
        }
        return out.prefix(limit).map { $0 }
    }
}

extension Double {
    var kgText: String { formatted(.number.precision(.fractionLength(0...1))) }
}
