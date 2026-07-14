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
    var restEndsAt: Date?
    var restFired = false
    @ObservationIgnored private var restTask: Task<Void, Never>?

    func startRest(seconds: Int) {
        guard seconds > 0 else { return }
        startRest(until: .now.addingTimeInterval(Double(seconds)))
    }

    func startRest(until end: Date) {
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
            }
        }
    }

    func stopRest() {
        restTask?.cancel()
        restEndsAt = nil
        Notifier.shared.cancelRest()
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
    /// Geplande trainingsdagen (Calendar weekday 1=zo…7=za). Leeg = geen vaste dagen.
    var trainingDays: [Int] = []

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
    // ponytail: offset wordt bij het opslaan verrekend, niet met terugwerkende kracht
    var offset: Double = 0
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

@Model
final class ProteinEntry {
    var date: Date
    var grams: Int
    var label: String
    var kcal: Int = 0
    var meal: String = "" // "breakfast" | "lunch" | "dinner" | "snack"; leeg = raden op tijdstip
    init(date: Date = .now, grams: Int, label: String, kcal: Int = 0, meal: String = "") {
        self.date = date
        self.grams = grams
        self.label = label
        self.kcal = kcal
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

struct Ingredient: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var protein: Int
    var kcal: Int
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
    init(date: Date = .now, exercise: String, weightKg: Double, reps: Int) {
        self.date = date
        self.exercise = exercise
        self.weightKg = weightKg
        self.reps = reps
    }
}

@Model
final class Routine {
    var name: String
    var exercises: [String]
    var createdAt: Date
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
}

extension Array where Element == WeightEntry {
    /// Gemiddeld gewicht binnen een venster van dagen terug, bv. 0..<7 = afgelopen week.
    func average(daysBack range: Range<Int>) -> Double? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let slice = filter {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: $0.date), to: today).day ?? 0
            return range.contains(d)
        }
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
    static func perfect(_ day: Date, proteins: [ProteinEntry], weights: [WeightEntry], habits: [DayHabits],
                        target: Int, requireCreatine: Bool = true, requireSleep: Bool = true,
                        sets: [SetEntry] = [], trainingDays: [Int] = []) -> Bool {
        let cal = Calendar.current
        let proteinDone = proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.grams).reduce(0, +) >= target
        let weighed = weights.contains { cal.isDate($0.date, inSameDayAs: day) }
        let h = habits.first { cal.isDate($0.date, inSameDayAs: day) }
        let creatineOK = !requireCreatine || h?.creatine == true
        let sleepOK = !requireSleep || h?.sleptEnough == true
        var trainingOK = true
        if trainingDays.contains(cal.component(.weekday, from: day)) {
            trainingOK = sets.contains { cal.isDate($0.date, inSameDayAs: day) }
        }
        return proteinDone && weighed && creatineOK && sleepOK && trainingOK
    }

    static func streak(proteins: [ProteinEntry], weights: [WeightEntry], habits: [DayHabits],
                       target: Int, requireCreatine: Bool = true, requireSleep: Bool = true,
                       sets: [SetEntry] = [], trainingDays: [Int] = []) -> Int {
        let cal = Calendar.current
        var count = 0
        for n in 0..<365 {
            guard let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: .now)) else { break }
            if perfect(day, proteins: proteins, weights: weights, habits: habits, target: target,
                       requireCreatine: requireCreatine, requireSleep: requireSleep,
                       sets: sets, trainingDays: trainingDays) { count += 1 }
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
