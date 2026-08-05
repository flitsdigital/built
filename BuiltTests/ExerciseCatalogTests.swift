import Foundation
import SwiftData
import Testing
@testable import Built

/// De catalogus is de enige tabel die de app zélf zaait, en dus de enige waar twee
/// toestellen los van elkaar dezelfde rij kunnen aanmaken. Sinds de pull samenvoegt in
/// plaats van vervangt is dat meteen zichtbaar: dezelfde oefening twee keer in de kiezer.
@Suite("Oefeningcatalogus")
struct ExerciseCatalogTests {

    @Test("Dezelfde naam onder twee id's wordt één rij")
    @MainActor func dubbeleOefeningWordtEen() throws {
        let context = try memoryContext()
        let afgeleid = Exercise(name: "Bench Press", muscle: "Borst", type: "Barbell")
        afgeleid.syncID = .stable(from: "Bench Press")
        let oud = Exercise(name: "Bench Press", muscle: "Borst", type: "Barbell") // gezaaid vóór #43
        let oudID = oud.syncID
        store([afgeleid, oud], in: context)

        Sync.clearDeletionsForTesting()
        Exercise.dedupe(context)

        let over = try context.fetch(FetchDescriptor<Exercise>())
        #expect(over.count == 1)
        #expect(over.first?.syncID == .stable(from: "Bench Press"))

        // Zonder spoor voor de server staat de verliezer er na de volgende pull weer.
        let spoor = Sync.pendingDeletionsForTesting
        #expect(spoor.count == 1)
        #expect(spoor.first?.id == oudID)
        #expect(spoor.first?.table == "exercises")
        Sync.clearDeletionsForTesting()
    }

    /// Het gevaarlijke geval: kiest toestel A een andere blijver dan toestel B, dan wist
    /// ieder de rij van de ander en houd je er nul over. De keuze mag dus alleen van de
    /// id's zelf afhangen — niet van volgorde, niet van wanneer een rij binnenkwam.
    @Test("Elk toestel houdt dezelfde rij over")
    @MainActor func blijverIsOveralDezelfde() throws {
        let laag = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let hoog = try #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))

        func blijver(_ ids: [UUID]) throws -> UUID {
            let context = try memoryContext()
            for id in ids {
                let row = Exercise(name: "Farmer Walk")
                row.syncID = id
                context.insert(row)
            }
            Exercise.dedupe(context)
            let over = try context.fetch(FetchDescriptor<Exercise>())
            #expect(over.count == 1)
            let blijft = try #require(over.first)
            return blijft.syncID
        }

        Sync.clearDeletionsForTesting()
        let eerst = try blijver([laag, hoog])
        let omgekeerd = try blijver([hoog, laag]) // andere volgorde, dezelfde uitkomst
        let metAfgeleid = try blijver([hoog, .stable(from: "Farmer Walk"), laag])
        #expect(eerst == laag)
        #expect(omgekeerd == laag)
        // En zodra de van de naam afgeleide rij meedoet, wint die van allebei.
        #expect(metAfgeleid == .stable(from: "Farmer Walk"))
        Sync.clearDeletionsForTesting()
    }

    @Test("Samenvoegen bewaart wat de andere rij wist")
    @MainActor func samenvoegenBewaartInformatie() throws {
        let context = try memoryContext()
        // De blijver: afgeleid id, maar nooit ingedeeld.
        let afgeleid = Exercise(name: "Hip Thrust")
        afgeleid.syncID = .stable(from: "Hip Thrust")
        afgeleid.createdAt = daysAgo(1)
        // De verliezer: wél ingedeeld, en ouder.
        let oud = Exercise(name: "Hip Thrust", muscle: "Bilspieren", type: "Barbell",
                           secondaryMuscles: ["Hamstrings"])
        oud.createdAt = daysAgo(400)
        store([afgeleid, oud], in: context)

        Sync.clearDeletionsForTesting()
        Exercise.dedupe(context)

        let rijen = try context.fetch(FetchDescriptor<Exercise>())
        let over = try #require(rijen.first)
        #expect(rijen.count == 1)
        #expect(over.syncID == .stable(from: "Hip Thrust"))
        #expect(over.muscle == "Bilspieren")
        #expect(over.type == "Barbell")
        #expect(over.secondaryMuscles == ["Hamstrings"])
        #expect(over.createdAt == daysAgo(400))
        Sync.clearDeletionsForTesting()
    }

    @Test("Een gezonde catalogus blijft ongemoeid")
    @MainActor func geenDubbelenGeenWijziging() throws {
        let context = try memoryContext()
        UserDefaults.standard.set(true, forKey: "seededCardio")
        Sync.clearDeletionsForTesting()

        Exercise.bootstrap(context)
        let na = try context.fetch(FetchDescriptor<Exercise>())
        Exercise.bootstrap(context) // tweede start

        let nogSteeds = try context.fetch(FetchDescriptor<Exercise>())
        #expect(nogSteeds.count == na.count)
        #expect(Set(nogSteeds.map(\.name)).count == nogSteeds.count)
        #expect(Sync.pendingDeletionsForTesting.isEmpty)
        Sync.clearDeletionsForTesting()
    }

    /// Een naam uit de historie is geen invoer maar een gegeven: twee toestellen met
    /// dezelfde training halen 'm allebei op. Met een willekeurig id staat hij daarna dus
    /// twee keer in de bibliotheek.
    @Test("Een naam uit de historie krijgt op elk toestel hetzelfde id")
    @MainActor func vrijeTekstKrijgtAfgeleidID() throws {
        let context = try memoryContext()
        context.insert(SetEntry(exercise: "Zercher Squat", weightKg: 60, reps: 5))
        UserDefaults.standard.set(true, forKey: "seededCardio")
        Sync.clearDeletionsForTesting()

        Exercise.bootstrap(context)

        let rijen = try context.fetch(FetchDescriptor<Exercise>())
        let rij = try #require(rijen.first { $0.name == "Zercher Squat" })
        #expect(rij.syncID == .stable(from: "Zercher Squat"))
        Sync.clearDeletionsForTesting()
    }
}
