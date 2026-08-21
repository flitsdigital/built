import Foundation
import SwiftData
import Testing
import UIKit
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

/// Het deelplaatje komt uit een `ImageRenderer`, en die geeft stilletjes nil als de kaart
/// niet te tekenen is. Dan biedt de deelknop niets aan zonder dat iemand het merkt —
/// deze suite is er om dat wél te zien.
@Suite("Training delen")
struct WorkoutShareTests {
    private func voorbeeld(lines: [WorkoutShareLine], prs: [(exercise: String, new: Double, old: Double)]) -> WorkoutShareImage {
        WorkoutShareImage(title: "Push A", date: "maandag 18 augustus", duration: "52 min",
                          volume: 4320, sets: 18, lines: lines, prs: prs)
    }

    @Test("De kaart levert een PNG op de breedte die een story wil")
    @MainActor func rendert() throws {
        let image = voorbeeld(lines: [WorkoutShareLine(exercise: "Bench Press", sets: "60×8  60×8"),
                                      WorkoutShareLine(exercise: "Dips", sets: "×10  +5×8")],
                              prs: [("Bench Press", 75, 72.5)])
        let png = try #require(image.png())
        let bitmap = try #require(UIImage(data: png))
        #expect(bitmap.size.width * bitmap.scale == 1080)
        #expect(bitmap.size.height > bitmap.size.width) // staand, niet een streepje
    }

    /// Een training zonder oefeningen bestaat: je kunt in de historie alle sets wissen.
    /// De kaart moet dan nog steeds te maken zijn, anders valt de deelknop stil.
    @Test("Zonder oefeningen en records blijft er een kaart over")
    @MainActor func leeg() {
        #expect(voorbeeld(lines: [], prs: []).png() != nil)
    }
}
