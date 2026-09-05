import Foundation
import SwiftData
import Testing
@testable import Built

/// Een training was "alles wat je die dag deed". Twee trainingen op één dag schoven
/// daardoor in elkaar. `sessions()` is de plek waar dat nu uit elkaar valt — en waar de
/// sets van vóór `workoutID` alsnog per dag bij elkaar moeten blijven.
@Suite("Trainingssessies")
struct WorkoutSessionTests {

    @Test("Twee trainingen op één dag blijven twee trainingen")
    @MainActor func tweePerDag() {
        let ochtend = UUID(), avond = UUID()
        let sets = [
            SetEntry(date: nlDate(2026, 8, 5, 9), exercise: "Bench Press", weightKg: 60, reps: 8, workoutID: ochtend),
            SetEntry(date: nlDate(2026, 8, 5, 9, 10), exercise: "Chest Fly", weightKg: 20, reps: 12, workoutID: ochtend),
            SetEntry(date: nlDate(2026, 8, 5, 19), exercise: "Squat", weightKg: 80, reps: 5, workoutID: avond),
        ]

        let sessions = sets.sessions()

        #expect(sessions.count == 2)
        #expect(sessions.first?.sets.map(\.exercise) == ["Bench Press", "Chest Fly"])
        #expect(sessions.last?.sets.map(\.exercise) == ["Squat"])
        // Oplopend op tijd: de historie draait het pas om.
        #expect(sessions.first!.date < sessions.last!.date)
    }

    /// Zonder deze terugval zou elke set van vóór deze versie z'n eigen "training" worden.
    @Test("Sets zonder sessie-id vallen per dag samen")
    @MainActor func oudeSetsPerDag() {
        let sets = [
            SetEntry(date: nlDate(2026, 8, 5, 9), exercise: "Bench Press", weightKg: 60, reps: 8),
            SetEntry(date: nlDate(2026, 8, 5, 19), exercise: "Squat", weightKg: 80, reps: 5),
            SetEntry(date: nlDate(2026, 8, 6, 9), exercise: "Deadlift", weightKg: 100, reps: 3),
        ]

        let sessions = sets.sessions()

        #expect(sessions.count == 2)
        #expect(sessions.first?.sets.count == 2)
    }

    /// Een dag met oude én nieuwe sets: die van vandaag horen niet in de oude bak.
    @Test("Een nieuwe training naast oude sets van dezelfde dag")
    @MainActor func gemengdeDag() {
        let nieuw = UUID()
        let sets = [
            SetEntry(date: nlDate(2026, 8, 5, 9), exercise: "Bench Press", weightKg: 60, reps: 8),
            SetEntry(date: nlDate(2026, 8, 5, 19), exercise: "Squat", weightKg: 80, reps: 5, workoutID: nieuw),
        ]

        let sessions = sets.sessions()

        #expect(sessions.count == 2)
        #expect(sessions.last?.id == nieuw.uuidString)
    }

    /// Naam en notitie staan per sessie, met de dagwaarde als terugval voor alles wat er
    /// al stond.
    @Test("Naam per sessie, met de oude dagnaam als terugval")
    @MainActor func naamPerSessie() {
        let habits = DayHabits(date: nlDate(2026, 8, 5, 12))
        habits.workoutName = "Push A"

        #expect(habits.name(for: "dag-123") == "Push A")

        habits.workoutNames["sessie-2"] = "Legs"
        #expect(habits.name(for: "sessie-2") == "Legs")
        #expect(habits.name(for: "dag-123") == "Push A")
        // Een nieuwe training van diezelfde dag erft "Push A" niet.
        #expect(habits.name(for: UUID().uuidString) == "")
    }
}

/// De concepttoestand op schijf. Zonder `entryID` was een herstelde training z'n koppeling
/// met de al opgeslagen rijen kwijt, en dat is waar de datums uit elkaar liepen: terugdateren
/// sloeg die sets over, annuleren liet ze staan, en een vinkje weghalen verwijderde de
/// verkeerde rij.
@Suite("Herstelde training")
struct SavedWorkoutTests {

    private func snapshot(_ set: SavedWorkout.SavedSet) -> SavedWorkout {
        SavedWorkout(startedAt: nlDate(2026, 8, 5, 9),
                     exercises: [.init(name: "Bench Press", tip: nil, note: "", sets: [set])])
    }

    @Test("Het id van de opgeslagen rij overleeft een force-quit")
    func entryIDRondtrip() throws {
        let id = UUID()
        let saved = snapshot(.init(kg: 60, reps: 8, done: true, entryID: id))
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedWorkout.self, from: data)
        #expect(back.exercises.first?.sets.first?.entryID == id)
    }

    @Test("Een concept van vóór deze kolom laadt nog steeds")
    func oudConceptLaadt() throws {
        let json = """
        {"startedAt":781340400,"exercises":[{"name":"Bench Press","note":"",
        "sets":[{"kg":60,"reps":8,"done":true}]}]}
        """
        let back = try JSONDecoder().decode(SavedWorkout.self, from: Data(json.utf8))
        #expect(back.exercises.first?.sets.first?.entryID == nil)
        #expect(back.exercises.first?.sets.first?.kg == 60)
    }
}

/// Warming-up-sets worden bewaard (#105), maar mogen nergens meetellen: één vergeten
/// filter en je weekvolume klopt niet meer.
@Suite("Warming-up")
struct WarmupTests {
    @Test("`.work` laat de warming-up buiten de telling")
    @MainActor func warmupTeltNietMee() {
        let sets = [
            SetEntry(exercise: "Squat", weightKg: 40, reps: 10, warmup: true),
            SetEntry(exercise: "Squat", weightKg: 60, reps: 8, warmup: true),
            SetEntry(exercise: "Squat", weightKg: 100, reps: 5),
            SetEntry(exercise: "Squat", weightKg: 100, reps: 5),
        ]
        #expect(sets.count == 4)
        #expect(sets.work.count == 2)
        let volume: Double = sets.work.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
        #expect(volume == 1000)
        // De opwarmset weegt lichter dan de werkset, dus een gemist filter valt op in het
        // volume — maar níét in het topgewicht. Vandaar ook hier expliciet.
        #expect(sets.work.map(\.weightKg).max() == 100)
    }

    @Test("De notatie markeert een warming-up")
    func warmupInNotatie() {
        #expect(setNotation(kg: 40, reps: 10, bodyweight: false, warmup: true) == "W40×10")
        #expect(setNotation(kg: 40, reps: 10, bodyweight: false) == "40×10")
    }
}
