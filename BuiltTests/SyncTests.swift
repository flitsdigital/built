import Foundation
import SwiftData
import Testing
@testable import Built

/// De sync heeft geen server nodig om te testen: de interessante beslissingen zitten in
/// de pure functies eromheen — hoe de payload eruitziet, en wie welk id krijgt.
@Suite("Sync")
struct SyncTests {

    // MARK: - Encoder

    /// Zonder `sortedKeys` heeft dezelfde data geen vaste JSON-vorm: `schedule`, `targets`
    /// en `exercise_notes` zijn dictionaries. Dan verschilt de vingerafdruk zonder dat er
    /// iets veranderd is, en pusht de app de volledige database voor niets.
    @Test("Encoder geeft dezelfde bytes voor dezelfde data")
    func encoderIsStabiel() throws {
        struct Row: Codable {
            var schedule: [String: String]
            var date: Date
        }
        let row = Row(schedule: ["4": "Pull", "2": "Push", "6": "Legs", "1": "Rust", "3": "Rest"],
                      date: nlDate(2025, 6, 2))

        let first = try Sync.makeEncoder().encode(row)
        for _ in 0..<20 {
            let again = try Sync.makeEncoder().encode(row)
            #expect(again == first)
        }

        let json = try #require(String(data: first, encoding: .utf8))
        // Sleutels op volgorde, en de datum als ISO8601 — niet als kaal getal, want dat
        // zou Postgres niet als timestamptz slikken.
        let eerste = try #require(json.range(of: "\"1\""))
        let tweede = try #require(json.range(of: "\"2\""))
        #expect(eerste.lowerBound < tweede.lowerBound)
        #expect(json.contains("2025-06-02T"))
    }

    // MARK: - Payload

    /// `sync_push` haalt de uid uit de sessie en negeert wat de client meestuurt, dus
    /// `user_id` in elke rij was dood gewicht — ~24% van de payload. De export liet dat
    /// zien als een placeholder-uuid die nergens op sloeg.
    @Test("Payload en export dragen geen user_id meer mee")
    @MainActor func payloadZonderUserID() throws {
        let context = try memoryContext()
        context.insert(Profile(name: "Jordi", age: 30, heightCm: 180, startWeight: 60,
                               goalWeight: 62.5, goalDate: nlDate(2026, 1, 1), trainingsPerWeek: 4))
        context.insert(WeightEntry(date: nlDate(2025, 6, 2), kg: 80))
        context.insert(SetEntry(date: nlDate(2025, 6, 2), exercise: "Squat", weightKg: 60, reps: 5))

        let json = try #require(Sync.exportJSON(context))
        #expect(!json.contains("user_id"))
        #expect(json.contains("\"exercise\""))
        #expect(json.contains("\"kg\""))
    }

    // MARK: - Sync-identiteit

    /// De standaardcatalogus zaait elk toestel zelf. Vallen die id's niet overal hetzelfde
    /// uit, dan zet een merge-pull dezelfde oefening er een tweede keer naast. Deze waarde
    /// mag dus nooit meer veranderen — vandaar vastgepind en niet "a == a".
    @Test("Afgeleid id blijft over versies heen hetzelfde")
    func stabielIDIsVastgepind() {
        #expect(UUID.stable(from: "Bench Press").uuidString == "80E59534-C87E-5A38-A691-43017AE26A1B")
        #expect(UUID.stable(from: "Bench Press") == UUID.stable(from: "Bench Press"))
        #expect(UUID.stable(from: "Bench Press") != UUID.stable(from: "Deadlift"))
    }

    /// Zonder stabiel id kan de client geen enkele rij aanwijzen, en is "alles wissen en
    /// opnieuw schrijven" het enige dat server en toestel gelijk trekt.
    @Test("Nieuwe rijen krijgen meteen een eigen syncID")
    @MainActor func nieuweRijenKrijgenEenID() throws {
        let a = SetEntry(exercise: "Squat", weightKg: 60, reps: 5)
        let b = SetEntry(exercise: "Squat", weightKg: 60, reps: 5)
        #expect(a.syncID != .zero)
        #expect(a.syncID != b.syncID)
        #expect(SetEntry.syncTable == "set_entries")
    }

    /// De sentinel is er omdat SwiftData de default van een nieuw attribuut één keer
    /// evalueert: met `= UUID()` zouden álle bestaande rijen dezelfde waarde krijgen.
    @Test("Rijen van vóór de update krijgen alsnog een uniek id")
    @MainActor func backfillDeeltIDsUit() throws {
        let context = try memoryContext()
        let rows = store((0..<3).map { _ in WeightEntry(kg: 80) }, in: context)
        for row in rows { row.syncID = .zero } // zoals ze uit de migratie zouden komen

        UserDefaults.standard.removeObject(forKey: "syncIdentityBackfilled")
        SyncIdentity.backfill(context)

        #expect(rows.allSatisfy { $0.syncID != .zero })
        #expect(Set(rows.map(\.syncID)).count == 3)
    }

    /// Twee toestellen die verschillend kiezen wie blijft, wissen elkaars keuze weg. Het
    /// afgeleide id is daarom de enige keuze die overal hetzelfde uitvalt.
    @Test("Dubbele oefening valt terug op één rij met het afgeleide id")
    @MainActor func dedupeHoudtDeAfgeleideRijOver() throws {
        let context = try memoryContext()
        Sync.clearDeletionsForTesting()
        let oud = Exercise(name: "Bench Press", muscle: "Borst", type: "Barbell") // willekeurig id
        let nieuw = Exercise(name: "Bench Press", muscle: "Borst", type: "Barbell")
        nieuw.syncID = .stable(from: "Bench Press")
        context.insert(oud)
        context.insert(nieuw)
        let oudID = oud.syncID
        context.insert(SetEntry(exercise: "Bench Press", weightKg: 60, reps: 5))

        Exercise.dedupe(context)

        let over = try context.fetch(FetchDescriptor<Exercise>())
        #expect(over.count == 1)
        #expect(over.first?.syncID == .stable(from: "Bench Press"))
        // De sets koppelen op naam, dus die hangen aan de overgebleven rij.
        #expect(try context.fetch(FetchDescriptor<SetEntry>()).count == 1)
        // En de server hoort te weten dat het duplicaat weg mag.
        #expect(Sync.pendingDeletionsForTesting.contains { $0.id == oudID })
    }

    @Test("Oefening zonder afgeleid id krijgt het alsnog, met spoor voor de oude")
    @MainActor func dedupeHerstempeltLosseRij() throws {
        let context = try memoryContext()
        Sync.clearDeletionsForTesting()
        let solo = Exercise(name: "Zelfbedachte Curl")
        context.insert(solo)
        let oudID = solo.syncID

        Exercise.dedupe(context)

        #expect(try context.fetch(FetchDescriptor<Exercise>()).count == 1)
        #expect(solo.syncID == .stable(from: "Zelfbedachte Curl"))
        #expect(Sync.pendingDeletionsForTesting.contains { $0.id == oudID })
    }

    // MARK: - Sync-log

    /// Zonder bovengrens groeit het log ongemerkt door in UserDefaults, en dat wordt bij
    /// elke sync opnieuw geëncodeerd. De grens is dus geen detail maar de reden dat dit
    /// log in UserDefaults mág staan.
    @Test("Het log roteert en houdt de nieuwste bovenaan")
    @MainActor func logRoteert() {
        SyncLog.clearForTesting()
        for i in 0..<250 { SyncLog.shared.record(.push, rows: ["sets": i]) }

        #expect(SyncLog.shared.entries.count == 200)
        #expect(SyncLog.shared.entries.first?.rows["sets"] == 249)
        #expect(SyncLog.shared.entries.last?.rows["sets"] == 50)
        SyncLog.clearForTesting()
    }

    /// Een mislukte push is precies de regel waarvoor dit log bestaat (#42): de statusregel
    /// is na de volgende geslaagde push weer groen, deze regel blijft staan.
    @Test("Een mislukte sync houdt z'n foutmelding, een geslaagde z'n aantallen")
    @MainActor func logToontFoutEnAantallen() {
        SyncLog.clearForTesting()
        SyncLog.shared.record(.push, error: "column \"tracks_food\" does not exist")
        SyncLog.shared.record(.pull, rows: ["sets": 12, "gewicht": 3])

        let geslaagd = SyncLog.shared.entries[0]
        #expect(geslaagd.error == nil)
        #expect(geslaagd.summary == "12 sets · 3 gewicht")

        let mislukt = SyncLog.shared.entries[1]
        #expect(mislukt.error?.contains("tracks_food") == true)
        #expect(mislukt.summary == "niets gewijzigd")
        SyncLog.clearForTesting()
    }

    @Test("Verwijderen laat een spoor achter voor de server")
    @MainActor func verwijderenLaatSpoorAchter() throws {
        let context = try memoryContext()
        let entry = WeightEntry(kg: 80)
        context.insert(entry)
        let id = entry.syncID

        Sync.clearDeletionsForTesting()
        context.deleteSynced(entry)

        let spoor = Sync.pendingDeletionsForTesting
        #expect(spoor.count == 1)
        #expect(spoor.first?.id == id)
        #expect(spoor.first?.table == "weight_entries")
        Sync.clearDeletionsForTesting()
    }

}
