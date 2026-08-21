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

/// Een training is achteraf aanpasbaar, dus je eigen historie is dat ook. `SetEdit.record`
/// is de plek waar dat een spoor achterlaat — en waar het typen van één nieuwe waarde
/// één regel moet blijven, niet vier.
@Suite("Trainingshistorie")
struct SetEditTests {

    @Test("Typen levert één regel op, van de oude naar de laatste waarde")
    @MainActor func typenIsEenWijziging() throws {
        let context = try memoryContext()

        // Zoals NumericField terugschrijft: per toetsaanslag.
        for (old, new) in [("90", "1"), ("1", "10"), ("10", "100")] {
            SetEdit.record(.kg, session: "s", exercise: "Squat", setNumber: 1,
                           from: old, to: new, in: context)
        }

        let rows = try context.fetch(FetchDescriptor<SetEdit>())
        #expect(rows.count == 1)
        #expect(rows.first?.oldValue == "90")
        #expect(rows.first?.newValue == "100")
        #expect(rows.first?.summary == "90 → 100 kg")
        #expect(rows.first?.subject == "Squat set 1")
    }

    /// Anders staat er een spoor van niets: je hebt gekeken, niet gewijzigd.
    @Test("Terugzetten op de oude waarde laat geen spoor achter")
    @MainActor func terugzettenWistDeRegel() throws {
        let context = try memoryContext()

        SetEdit.record(.kg, session: "s", exercise: "Squat", setNumber: 1,
                       from: "90", to: "100", in: context)
        SetEdit.record(.kg, session: "s", exercise: "Squat", setNumber: 1,
                       from: "100", to: "90", in: context)

        #expect(try context.fetch(FetchDescriptor<SetEdit>()).isEmpty)
    }

    /// Twee sets van dezelfde oefening zijn twee wijzigingen; de datum hoort bij de hele
    /// training en heeft daarom geen oefening of setnummer.
    @Test("Elk veld en elke set krijgt een eigen regel")
    @MainActor func elkVeldEigenRegel() throws {
        let context = try memoryContext()

        SetEdit.record(.kg, session: "s", exercise: "Squat", setNumber: 1, from: "90", to: "100", in: context)
        SetEdit.record(.kg, session: "s", exercise: "Squat", setNumber: 2, from: "90", to: "100", in: context)
        SetEdit.record(.reps, session: "s", exercise: "Squat", setNumber: 1, from: "8", to: "10", in: context)
        SetEdit.record(.datum, session: "s", from: "5 aug 2026", to: "6 aug 2026", in: context)

        let rows = try context.fetch(FetchDescriptor<SetEdit>())
        #expect(rows.count == 4)
        let datum = try #require(rows.first { $0.field == "datum" })
        #expect(datum.subject == "Datum")
        #expect(datum.summary == "5 aug 2026 → 6 aug 2026")
    }

    /// Zonder bewaartermijn groeit het spoor op elk toestel mee tot in het oneindige.
    @Test("Wijzigingen ouder dan de bewaartermijn worden opgeruimd")
    @MainActor func bewaartermijn() throws {
        let context = try memoryContext()
        Sync.clearDeletionsForTesting()
        let oud = SetEdit(session: "s", exercise: "Squat", setNumber: 1, field: .kg,
                          from: "90", to: "100", at: daysAgo(SetEdit.retentionDays + 1))
        let vers = SetEdit(session: "s", exercise: "Squat", setNumber: 2, field: .kg,
                           from: "90", to: "100", at: daysAgo(1))
        store([oud, vers], in: context)
        let oudID = oud.syncID

        SetEdit.prune(context)

        let rows = try context.fetch(FetchDescriptor<SetEdit>())
        #expect(rows.count == 1)
        #expect(rows.first?.setNumber == 2)
        // En de server hoort te weten dat de oude regel weg mag.
        #expect(Sync.pendingDeletionsForTesting.contains { $0.id == oudID })
        Sync.clearDeletionsForTesting()
    }
}
