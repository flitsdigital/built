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

/// De rusttimer stond op een getal dat je zelf ooit had ingetypt. Nu leest hij af hoe lang
/// je feitelijk tussen twee sets zit — en dan mag één telefoontje die schatting niet
/// minutenlang optillen.
@Suite("Rustschatting")
struct RestEstimateTests {

    /// Sets van één sessie, met de opgegeven pauzes (in seconden) ertussen.
    @MainActor private func sessie(_ start: Date, _ gaps: [Int], exercise: String = "Bench Press",
                                   id: UUID = UUID()) -> [SetEntry] {
        var t = start
        var rows = [SetEntry(date: t, exercise: exercise, weightKg: 60, reps: 8, workoutID: id)]
        for gap in gaps {
            t = t.addingTimeInterval(Double(gap))
            rows.append(SetEntry(date: t, exercise: exercise, weightKg: 60, reps: 8, workoutID: id))
        }
        return rows
    }

    @Test("De mediaan van de tijd tussen twee sets, op vijf seconden afgerond")
    @MainActor func mediaan() {
        let sets = sessie(nlDate(2026, 8, 5, 9), [92, 88, 94, 91])

        #expect(sets.restEstimate(for: "Bench Press") == 90)
    }

    @Test("Een telefoontje van tien minuten telt niet mee")
    @MainActor func uitschieterBoven() {
        let sets = sessie(nlDate(2026, 8, 5, 9), [90, 600, 90, 90])

        // Zonder de bovengrens zou het gemiddelde hier op ruim drie en een halve minuut uitkomen.
        #expect(sets.restEstimate(for: "Bench Press") == 90)
    }

    @Test("Sets die achteraf in één keer zijn ingetikt tellen niet mee")
    @MainActor func uitschieterOnder() {
        let sets = sessie(nlDate(2026, 8, 5, 9), [2, 3, 120, 120, 120])

        #expect(sets.restEstimate(for: "Bench Press") == 120)
    }

    @Test("Te weinig metingen geeft geen schatting")
    @MainActor func teWeinig() {
        #expect([SetEntry]().restEstimate(for: "Bench Press") == nil)
        #expect(sessie(nlDate(2026, 8, 5, 9), [90, 90]).restEstimate(for: "Bench Press") == nil)
        #expect(sessie(nlDate(2026, 8, 5, 9), [90, 90, 90]).restEstimate(for: "Bench Press") == 90)
    }

    @Test("Elke oefening heeft z'n eigen tempo")
    @MainActor func perOefening() {
        let id = UUID()
        let bench = sessie(nlDate(2026, 8, 5, 9), [90, 90, 90], exercise: "Bench Press", id: id)
        let curl = sessie(nlDate(2026, 8, 5, 10), [45, 45, 45], exercise: "Biceps Curl", id: id)

        let sets = bench + curl

        #expect(sets.restEstimate(for: "Bench Press") == 90)
        #expect(sets.restEstimate(for: "Biceps Curl") == 45)
        #expect(sets.restEstimate(for: "Squat") == nil)
    }

    /// De sprong van de laatste set van de ene sessie naar de eerste van de volgende is
    /// dagen, geen rust. Zonder de knip per sessie zou die als uitschieter meetellen.
    @Test("Alleen binnen dezelfde sessie")
    @MainActor func nietOverSessiesHeen() {
        let sets = sessie(nlDate(2026, 8, 1, 9), [120, 120]) + sessie(nlDate(2026, 8, 5, 9), [120, 120])

        #expect(sets.restEstimate(for: "Bench Press") == 120)
    }

    /// Je bent sneller gaan trainen: de oude sessies mogen dat niet blijven uitvlakken.
    @Test("Alleen de laatste sessies tellen mee")
    @MainActor func alleenRecent() {
        var sets: [SetEntry] = []
        for dag in 1...6 { sets += sessie(nlDate(2026, 8, dag, 9), [180, 180, 180]) }
        for dag in 7...12 { sets += sessie(nlDate(2026, 8, dag, 9), [60, 60, 60]) }

        #expect(sets.restEstimate(for: "Bench Press") == 60)
    }
}
