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
    /// Hoeveelheid zoals gelogd, in `unit`. 0 = oudere invoer zonder portie; die blijft
    /// op macro-niveau bewerkbaar. Hiermee kun je "250 → 200 g" aanpassen zonder zelf
    /// vier macro's te herrekenen.
    var amount: Double = 0
    var unit: String = FoodUnit.gram.rawValue
    init(date: Date = .now, grams: Int, label: String, kcal: Int = 0, carbs: Int = 0, fat: Int = 0,
         meal: String = "", amount: Double = 0, unit: FoodUnit = .gram) {
        self.date = date
        self.grams = grams
        self.label = label
        self.kcal = kcal
        self.carbs = carbs
        self.fat = fat
        self.meal = meal
        self.amount = amount
        self.unit = unit.rawValue
    }

    var foodUnit: FoodUnit { FoodUnit(rawValue: unit) ?? .gram }

    /// Waarden per 100 g/ml, teruggerekend uit wat er gelogd is. nil bij oudere invoer
    /// zonder portie — dan is er niets om op te schalen.
    var per100: (protein: Double, kcal: Double, carbs: Double, fat: Double)? {
        guard amount > 0 else { return nil }
        let f = 100 / amount
        return (Double(grams) * f, Double(kcal) * f, Double(carbs) * f, Double(fat) * f)
    }

    /// Zet de hoeveelheid om en schaalt de macro's mee.
    func rescale(to newAmount: Double) {
        guard let p = per100, newAmount > 0 else { return }
        amount = newAmount
        grams = Int((p.protein * newAmount / 100).rounded())
        kcal = Int((p.kcal * newAmount / 100).rounded())
        carbs = Int((p.carbs * newAmount / 100).rounded())
        fat = Int((p.fat * newAmount / 100).rounded())
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

// MARK: - Porties en eenheden
//
// Je denkt niet in grammen maar in porties: "een glas melk", "een snee brood".
// Hieronder de vertaling van beide kanten op — welke eenheid hoort bij dit product,
// en welke vaste porties zijn zinnig om aan te bieden.

/// Drank log je in milliliters, de rest in grammen.
enum FoodUnit: String, Codable, CaseIterable {
    case gram = "g"
    case milliliter = "ml"

    var label: String { rawValue }

    /// Categorie-hints uit OpenFoodFacts. `categories_tags` is daar wél gevuld waar
    /// `product_quantity_unit` en `serving_size` leeg blijven — geverifieerd op melk,
    /// cola, brood en kwark. Substring-match, zodat `en:milks-liquid-and-powder` en
    /// `en:carbonated-drinks` ook meetellen.
    private static let drinkTagHints = ["beverage", "milk", "water", "juice", "drink",
                                        "soda", "tea", "coffee", "smoothie"]
    /// Terugval voor eigen producten, die geen categorieën hebben.
    private static let drinkWords = ["melk", "water", "sap", "jus", "cola", "koffie", "thee", "limonade",
                                     "frisdrank", "smoothie", "shake", "bier", "wijn", "drinkyoghurt"]

    /// Slimme gok, geen wet: in de portie-sheet kun je 'm altijd omzetten.
    static func detect(categories: [String], name: String) -> FoodUnit {
        let tags = categories.joined(separator: " ").lowercased()
        if drinkTagHints.contains(where: tags.contains) { return .milliliter }
        guard categories.isEmpty else { return .gram } // categorieën bekend en niet-drank → klaar
        let lower = name.lowercased()
        return drinkWords.contains(where: lower.contains) ? .milliliter : .gram
    }
}

/// Eén aanklikbare portie: "1 glas" → 250 ml.
struct FoodPortion: Identifiable, Hashable {
    var label: String
    var amount: Double
    var id: String { label }
}

enum FoodPortions {
    private static let drink = [FoodPortion(label: "Klein glas", amount: 200),
                               FoodPortion(label: "1 glas", amount: 250),
                               FoodPortion(label: "Groot glas", amount: 330),
                               FoodPortion(label: "Blikje", amount: 330),
                               FoodPortion(label: "Fles", amount: 500)]
    private static let bread = [FoodPortion(label: "1 snee", amount: 35),
                               FoodPortion(label: "1 broodje", amount: 60),
                               FoodPortion(label: "1 bolletje", amount: 50)]
    private static let egg = [FoodPortion(label: "1 ei", amount: 60),
                             FoodPortion(label: "2 eieren", amount: 120)]
    private static let dairy = [FoodPortion(label: "1 bakje", amount: 150),
                               FoodPortion(label: "1 schaal", amount: 250),
                               FoodPortion(label: "1 el", amount: 15)]
    private static let spoon = [FoodPortion(label: "1 tl", amount: 5),
                               FoodPortion(label: "1 el", amount: 15)]
    private static let generic = [FoodPortion(label: "50 g", amount: 50),
                                 FoodPortion(label: "100 g", amount: 100),
                                 FoodPortion(label: "250 g", amount: 250)]

    /// Vaste porties voor dit product. Categorieën gaan voor; bij eigen producten
    /// beslist de naam. Valt terug op de oude 50/100/250.
    static func suggested(unit: FoodUnit, categories: [String], name: String) -> [FoodPortion] {
        if unit == .milliliter { return drink }
        let hay = (categories + [name]).joined(separator: " ").lowercased()
        if ["bread", "brood", "toast", "cracker", "beschuit"].contains(where: hay.contains) { return bread }
        if ["egg", ":ei", " ei", "eieren"].contains(where: hay.contains) { return egg }
        if ["spread", "oil", "sauce", "boter", "olie", "saus", "jam", "pindakaas"].contains(where: hay.contains) { return spoon }
        if ["dairies", "yogurt", "yoghurt", "kwark", "skyr", "cottage"].contains(where: hay.contains) { return dairy }
        return generic
    }
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
    /// "g" of "ml" — onthouden, zodat melk niet elke keer opnieuw in grammen begint.
    var unit: String = FoodUnit.gram.rawValue
    /// Laatst gelogde hoeveelheid; de logische startwaarde de volgende keer.
    var lastAmount: Double = 0
    /// OFF-categorieën, voor de portie-suggesties. Kommagescheiden gehouden zodat het
    /// één kolom blijft in de sync.
    var categories: String = ""

    var foodUnit: FoodUnit { FoodUnit(rawValue: unit) ?? .gram }
    var categoryList: [String] { categories.isEmpty ? [] : categories.components(separatedBy: ",") }

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
    /// Notitie per oefening. Stond eerder als `"Bench Press: voelde zwaar"`-regels in
    /// `note` gepropt en werd er op prefix weer uit geparsed — een relatie vermomd als
    /// tekst, die brak op een oefeningsnaam met een dubbele punt. `note` blijft staan
    /// voor wat er al in zit.
    var exerciseNotes: [String: String] = [:]
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
    /// Eén meetpunt van een dag: hoeveel hij weegt en hoe ver hij binnen is.
    struct Factor: Identifiable {
        let name: String
        let weight: Int
        /// 0…1. Eiwit telt naar rato, de rest is alles-of-niets.
        let progress: Double
        var id: String { name }
        var done: Bool { progress > 0.999 }
    }

    /// De enige definitie van "hoe goed was deze dag".
    ///
    /// Score, perfecte dag, streak en beide heatmaps leiden hier allemaal uit af.
    /// Daarvoor had elk z'n eigen lijstje en gaven ze verschillende antwoorden over
    /// dezelfde dag: een geplande rustdag was +25 op het dashboard en telde mee voor
    /// je streak, maar stond in de jaar-heatmap als gemist. Custom habits telden
    /// alleen in die jaar-heatmap mee.
    static func factors(_ day: Date, index: DayIndex, profile: Profile,
                        customHabits: [String] = []) -> [Factor] {
        var out: [Factor] = []
        if profile.tracksFood {
            let ratio = Double(index.protein(day)) / Double(max(profile.proteinTarget, 1))
            out.append(Factor(name: "Eiwit", weight: 30, progress: min(ratio, 1)))
        }
        // Rustdag volgens plan telt als gedaan — niet trainen ís dan het plan.
        let weekday = Calendar.current.component(.weekday, from: day)
        let restDay = !profile.trainingDays.isEmpty && !profile.trainingDays.contains(weekday)
        out.append(Factor(name: "Training", weight: 25,
                          progress: index.trained(day) || restDay ? 1 : 0))
        out.append(Factor(name: "Gewicht", weight: 15, progress: index.weighed(day) ? 1 : 0))
        let h = index.habits(day)
        if profile.tracksCreatine {
            out.append(Factor(name: "Creatine", weight: 15, progress: h?.creatine == true ? 1 : 0))
        }
        if profile.tracksSleep {
            out.append(Factor(name: "Slaap", weight: 15, progress: h?.sleptEnough == true ? 1 : 0))
        }
        for name in customHabits {
            out.append(Factor(name: name, weight: 10, progress: index.logged(name, on: day) ? 1 : 0))
        }
        return out
    }

    /// Gewogen vervulling, 0…100.
    ///
    /// 100 is gereserveerd voor een écht complete dag. Zonder die grens rondde
    /// 99,7% af naar 100 en zei het dashboard "Perfecte dag 🏆" terwijl `perfect`
    /// false was — je streak liep dan niet door en de heatmap kleurde de dag niet.
    /// Vanaf ~98,3% van je eiwitdoel was dat al bereikbaar.
    static func score(_ day: Date, index: DayIndex, profile: Profile,
                      customHabits: [String] = []) -> Int {
        let f = factors(day, index: index, profile: profile, customHabits: customHabits)
        let total = f.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let earned = f.reduce(0.0) { $0 + Double($1.weight) * $1.progress }
        let raw = Int((earned / Double(total) * 100).rounded())
        return f.allSatisfy(\.done) ? raw : min(raw, 99)
    }

    /// Perfecte dag = alles binnen, en dus per definitie score 100.
    static func perfect(_ day: Date, index: DayIndex, profile: Profile,
                        customHabits: [String] = []) -> Bool {
        factors(day, index: index, profile: profile, customHabits: customHabits).allSatisfy(\.done)
    }

    static func streak(index: DayIndex, profile: Profile, customHabits: [String] = []) -> Int {
        let cal = Calendar.current
        var count = 0
        for n in 0..<365 {
            guard let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: .now)) else { break }
            if perfect(day, index: index, profile: profile, customHabits: customHabits) { count += 1 }
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
