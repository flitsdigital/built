import SwiftUI
import SwiftData

// De concepttoestand van een lopende training: wat je invult voordat het als
// SetEntry de database in gaat. Stond bovenin TrainingView.swift, dat op 2144 regels
// niet meer te overzien was.

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
        /// De `syncID` van de rij die deze set al in de database heeft. Zonder dit is een
        /// herstelde training z'n koppeling kwijt: terugdateren sloeg die sets over,
        /// annuleren liet ze staan, en een vinkje weghalen verwijderde de verkeerde rij.
        var entryID: UUID?
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
    var workoutName: String?
    /// Teruggezette datum, zodat een force-quit hem niet op vandaag terugzet.
    var workoutDate: Date?
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

