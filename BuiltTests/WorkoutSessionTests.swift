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

/// Slepen tijdens een lopende training. De volgorde is weergave, op één ding na: een
/// superset bestaat alleen zolang de oefeningen naast elkaar staan, want dáár kijkt de
/// rusttimer naar.
@Suite("Volgorde tijdens een training")
struct WorkoutOrderTests {

    private func draft(_ name: String, superset: String? = nil) -> DraftExercise {
        DraftExercise(name: name, sets: [DraftSet(kg: 60, reps: 8)], superset: superset)
    }

    @Test("Slepen wisselt alleen de volgorde")
    @MainActor func volgordeWisselt() {
        let workout = [draft("Bench Press"), draft("Squat"), draft("Deadlift")]

        let out = workout.reordered(moving: IndexSet(integer: 2), to: 0)

        #expect(out.map(\.name) == ["Deadlift", "Bench Press", "Squat"])
        // De sets verhuizen mee met hun oefening, niet met de plek.
        #expect(out.first?.sets.first?.id == workout.last?.sets.first?.id)
    }

    @Test("Een oefening uit een superset slepen laat de groep achter")
    @MainActor func supersetValtUitElkaar() {
        let workout = [draft("Bench Press", superset: "A"), draft("Chest Fly", superset: "A"), draft("Squat")]

        // Squat ertussen: Bench en Fly staan niet meer naast elkaar.
        let out = workout.reordered(moving: IndexSet(integer: 2), to: 1)

        #expect(out.map(\.name) == ["Bench Press", "Squat", "Chest Fly"])
        #expect(out.allSatisfy { $0.superset == nil })
    }

    @Test("Een superset die heel blijft houdt z'n letter")
    @MainActor func supersetBlijftHeel() {
        let workout = [draft("Squat"), draft("Bench Press", superset: "A"), draft("Chest Fly", superset: "A")]

        // Het paar als geheel naar voren: ze blijven buren, dus de groep blijft staan.
        let out = workout.reordered(moving: IndexSet([1, 2]), to: 0)

        #expect(out.map(\.name) == ["Bench Press", "Chest Fly", "Squat"])
        #expect(out.prefix(2).allSatisfy { $0.superset == "A" })
    }

    @Test("Een groep van drie blijft staan als er één uit weggaat")
    @MainActor func restVanDeGroepBlijft() {
        let workout = [draft("Bench Press", superset: "A"), draft("Chest Fly", superset: "A"),
                       draft("Dips", superset: "A"), draft("Squat")]

        let out = workout.reordered(moving: IndexSet(integer: 2), to: 4)

        #expect(out.map(\.name) == ["Bench Press", "Chest Fly", "Squat", "Dips"])
        #expect(out[0].superset == "A" && out[1].superset == "A")
        #expect(out.last?.superset == nil)
    }
}
