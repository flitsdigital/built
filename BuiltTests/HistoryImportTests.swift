import Foundation
import SwiftData
import Testing
@testable import Built

/// Een import leest andermans bestand: de kolommen heten anders per app, de eenheid staat
/// er soms niet in, en de notities zitten vol komma's. Wat hier misgaat, gaat mis in je
/// historie — en die mag een import nooit overschrijven.
@Suite("Historie importeren")
struct HistoryImportTests {

    // Hevy: één tijdstempel per training, gewicht mét eenheid in de kop, set_type erbij.
    // De tijdstempels staan tussen aanhalingstekens omdat er een komma in zit — precies
    // waar een `split(separator: ",")` op zou stukgaan.
    private let hevy = """
    title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps,duration_seconds
    Push A,"22 Jan 2024, 17:22","22 Jan 2024, 18:30",Bench Press (Barbell),1,normal,60,8,
    Push A,"22 Jan 2024, 17:22","22 Jan 2024, 18:30",Bench Press (Barbell),2,failure,60,6,
    Pull A,"24 Jan 2024, 17:00","24 Jan 2024, 18:00",Barbell Row,1,normal,50,10,
    """

    // Strong: dezelfde velden onder andere namen, en de eenheid tussen haakjes.
    private let strong = """
    Date,Workout Name,Duration,Exercise Name,Set Order,Weight (lbs),Reps,Seconds,Notes
    2024-01-22 17:22:00,Push A,1h 8m,Bench Press,1,220,8,0,
    2024-01-22 17:22:00,Push A,1h 8m,Bench Press,2,220,8,0,
    """

    @Test("Hevy-export levert twee trainingen op")
    func hevyExport() throws {
        let preview = HistoryImport.parse(hevy)

        #expect(preview.sets.count == 3)
        #expect(preview.sessionCount == 2)
        #expect(preview.unit == .kg)
        #expect(preview.sets.first?.exercise == "Bench Press (Barbell)")
        #expect(preview.sets.first?.workoutName == "Push A")
        #expect(preview.sets[1].failure)
        #expect(preview.sets.first?.date == nlDate(2024, 1, 22, 17, 22))
    }

    /// De kop noemt de eenheid, dus er valt niets te kiezen — en ponden mogen niet als
    /// kilo's binnenkomen.
    @Test("Strong in ponden komt in kilo's binnen")
    @MainActor func strongInPonden() throws {
        let preview = HistoryImport.parse(strong)
        #expect(preview.unit == .lbs)

        let context = try memoryContext()
        HistoryImport.apply(preview.sets, unit: preview.unit ?? .kg, to: context)
        let saved = try context.fetch(FetchDescriptor<SetEntry>())

        #expect(saved.count == 2)
        #expect(saved.allSatisfy { abs($0.weightKg - 99.79) < 0.01 })
    }

    /// Zonder eenheid in de kop moet het scherm het vragen; hier alleen dat we het weten.
    @Test("Een kale gewichtskolom laat de eenheid open")
    func eenheidOnbekend() {
        let csv = """
        Date,Workout Name,Exercise Name,Set Order,Weight,Reps,Seconds
        2024-01-22 17:22:00,Push A,Bench Press,1,100,8,0
        """
        #expect(HistoryImport.parse(csv).unit == nil)
    }

    /// Een notitie met komma's en een regeleinde erin schoof zonder echte CSV-lezer alle
    /// kolommen erachter een plek op — en dan importeer je reps als gewicht.
    @Test("Een notitie met komma's houdt de kolommen op hun plek")
    func notitieMetKommas() {
        let csv = "Date,Workout Name,Exercise Name,Weight (kg),Reps,Notes\n"
            + "2024-01-22 17:22:00,Push A,Bench Press,60,8,\"zwaar, maar\nging goed\"\n"

        let preview = HistoryImport.parse(csv)

        #expect(preview.sets.count == 1)
        #expect(preview.sets.first?.weight == 60)
        #expect(preview.sets.first?.reps == 8)
    }

    /// Strong zet rustpauzes en losse notities als regels tussen de sets. Die tellen mee
    /// als overgeslagen, zodat het scherm het kan melden in plaats van ze te verzwijgen.
    @Test("Regels zonder reps en zonder duur tellen niet mee")
    func rustregelsOvergeslagen() {
        let csv = """
        Date,Workout Name,Exercise Name,Weight (kg),Reps,Seconds
        2024-01-22 17:22:00,Push A,Bench Press,60,8,0
        2024-01-22 17:22:00,Push A,Rest Timer,0,0,0
        niet-een-datum,Push A,Bench Press,60,8,0
        """

        let preview = HistoryImport.parse(csv)

        #expect(preview.sets.count == 1)
        #expect(preview.ignored == 2)
    }

    /// Hevy zet het materiaal achter de naam. Zonder deze normalisatie staat elke oefening
    /// straks twee keer in de bibliotheek en telt je vordering niet door.
    @Test("Materiaal tussen haakjes matcht op de bestaande oefening")
    func naamMatchen() {
        let catalogue = ["Bench Press", "Barbell Row"]

        #expect(HistoryImport.match("Bench Press (Barbell)", to: catalogue) == "Bench Press")
        #expect(HistoryImport.match("bench press", to: catalogue) == "Bench Press")
        #expect(HistoryImport.match("Zercher Squat", to: catalogue) == "Zercher Squat")
    }

    /// En hetzelfde langs de echte weg: de sets komen onder de naam uit de bibliotheek
    /// binnen, en er komt geen tweede oefening naast.
    @Test("Een geïmporteerde set landt op de bestaande oefening")
    @MainActor func matchtOpDeBibliotheek() throws {
        let context = try memoryContext()
        Exercise.bootstrap(context)
        let before = try context.fetch(FetchDescriptor<Exercise>()).count

        HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)

        let saved = try context.fetch(FetchDescriptor<SetEntry>())
        #expect(saved.contains { $0.exercise == "Bench Press" })
        #expect(!saved.contains { $0.exercise == "Bench Press (Barbell)" })
        // Alle drie de namen staan al in de catalogus, dus er komt niets bij.
        #expect(try context.fetch(FetchDescriptor<Exercise>()).count == before)
    }

    /// Drie keer 60 kg × 8 op één dag zijn drie sets. Een vingerafdruk zonder telling zou
    /// er twee weggooien.
    @Test("Identieke sets in dezelfde training blijven allemaal staan")
    @MainActor func identiekeSets() throws {
        let csv = """
        Date,Workout Name,Exercise Name,Weight (kg),Reps,Seconds
        2024-01-22 17:22:00,Push A,Bench Press,60,8,0
        2024-01-22 17:22:00,Push A,Bench Press,60,8,0
        2024-01-22 17:22:00,Push A,Bench Press,60,8,0
        """
        let context = try memoryContext()

        let result = HistoryImport.apply(HistoryImport.parse(csv).sets, unit: .kg, to: context)

        #expect(result.added == 3)
        #expect(try context.fetch(FetchDescriptor<SetEntry>()).count == 3)
    }

    /// Het vangnet: hetzelfde bestand twee keer kiezen mag je historie niet verdubbelen,
    /// en een tweede export met een nieuwe training erin mag niets verliezen.
    @Test("Hetzelfde bestand twee keer verdubbelt niets")
    @MainActor func tweeKeerImporteren() throws {
        let context = try memoryContext()
        // Zoals in de app: de bibliotheek staat er al vóór er iets te importeren valt.
        // Zonder dat matcht de eerste import op een lege catalogus en de tweede op een
        // gevulde, en dan herkent hij z'n eigen sets niet meer.
        Exercise.bootstrap(context)
        let first = HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)
        #expect(first.added == 3)

        let second = HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)

        #expect(second.added == 0)
        #expect(second.skipped == 3)
        #expect(try context.fetch(FetchDescriptor<SetEntry>()).count == 3)
    }

    /// Twee trainingen uit het bestand mogen niet in elkaar schuiven, en de sets binnen
    /// één training moeten in de volgorde van het bestand staan — het bestand geeft ze
    /// allemaal hetzelfde tijdstempel.
    @Test("Sessies en volgorde overleven de import")
    @MainActor func sessiesEnVolgorde() throws {
        let context = try memoryContext()
        HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)

        let sessions = try context.fetch(FetchDescriptor<SetEntry>()).sessions()

        #expect(sessions.count == 2)
        #expect(sessions.first?.sets.map(\.reps) == [8, 6])
        #expect(sessions.first?.sets.allSatisfy { $0.workoutID != .zero } == true)
        // Elke rij een eigen syncID, anders staat de historie na een pull dubbel.
        let ids = Set(try context.fetch(FetchDescriptor<SetEntry>()).map(\.syncID))
        #expect(ids.count == 3)
        #expect(!ids.contains(.zero))
    }

    /// Een import voegt toe. Een naam die er al staat blijft staan, ook als het bestand
    /// er een andere voor die training noemt.
    @Test("Een bestaande trainingsnaam blijft staan")
    @MainActor func naamNietOverschrijven() throws {
        let context = try memoryContext()
        Exercise.bootstrap(context)
        HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)

        let sets = try context.fetch(FetchDescriptor<SetEntry>()).sorted { $0.date < $1.date }
        let first = try #require(sets.first)
        let key = first.sessionKey
        let days = try context.fetch(FetchDescriptor<DayHabits>())
        let record = try #require(days.first { dayKey($0.date) == dayKey(first.date) })
        #expect(record.name(for: key) == "Push A")

        record.workoutNames[key] = "Zelf verzonnen"
        HistoryImport.apply(HistoryImport.parse(hevy).sets, unit: .kg, to: context)

        #expect(record.name(for: key) == "Zelf verzonnen")
    }
}
