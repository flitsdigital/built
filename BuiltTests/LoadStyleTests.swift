import Foundation
import Testing
@testable import Built

/// Het getal in een set betekent per oefening iets anders: last, extra gewicht, of hulp
/// van de machine. Bij die laatste is een hóger getal slechter — de enige plek in de app
/// waar de richting omdraait, en dus de enige plek waar een fout je een record toekent
/// omdat je zwakker werd.
@Suite("Assisted en bodyweight")
struct LoadStyleTests {
    @Test("Extern gewicht is gewoon het getal")
    func extern() {
        #expect(liftLoad(kg: 60, bodyweight: 80, style: .external) == 60)
        #expect(setNotation(kg: 60, reps: 8, style: .external) == "60×8")
    }

    @Test("Bodyweight telt je eigen gewicht erbij")
    func bodyweight() {
        #expect(liftLoad(kg: 0, bodyweight: 80, style: .bodyweight) == 80)
        #expect(liftLoad(kg: 10, bodyweight: 80, style: .bodyweight) == 90)
        #expect(setNotation(kg: 10, reps: 8, style: .bodyweight) == "+10×8")
        #expect(setNotation(kg: 0, reps: 8, style: .bodyweight) == "×8")
    }

    @Test("Assisted haalt de hulp van je lichaamsgewicht af")
    func assisted() {
        #expect(liftLoad(kg: 20, bodyweight: 80, style: .assisted) == 60)
        #expect(liftLoad(kg: 0, bodyweight: 80, style: .assisted) == 80)
        #expect(setNotation(kg: 20, reps: 8, style: .assisted) == "−20×8")
        #expect(setNotation(kg: 0, reps: 8, style: .assisted) == "×8")
    }

    /// Een machine die meer wegneemt dan je weegt bestaat niet, maar een typefout of een
    /// ontbrekende weging wel. Negatief volume zou de spierkaart en het dagtotaal slopen.
    @Test("Meer hulp dan je weegt komt op 0 uit, niet onder nul")
    func nooitNegatief() {
        #expect(liftLoad(kg: 200, bodyweight: 80, style: .assisted) == 0)
        #expect(liftLoad(kg: 20, bodyweight: 0, style: .assisted) == 0)
        #expect(liftLoad(kg: 20, bodyweight: -5, style: .assisted) == 0)
    }

    @Test("Cardio wint van de stijl: duur, geen gewicht")
    func cardio() {
        #expect(setNotation(kg: 0, reps: 0, style: .external, seconds: 1500) == "25 min")
        #expect(setNotation(kg: 20, reps: 8, style: .assisted, seconds: 600) == "10 min")
    }

    @Test("Het label bij het invoerveld toont de richting")
    func labels() {
        #expect(LoadStyle.external.kgLabel == "kg")
        #expect(LoadStyle.bodyweight.kgLabel == "+kg")
        #expect(LoadStyle.assisted.kgLabel == "−kg")
    }

    @Test("Het type uit de bibliotheek bepaalt de stijl")
    func uitType() {
        #expect(LoadStyle(type: "Bodyweight") == .bodyweight)
        #expect(LoadStyle(type: "Assisted") == .assisted)
        #expect(LoadStyle(type: "Barbell") == .external)
        #expect(LoadStyle(type: "Machine") == .external)
        // Onbekend of een oefening die niet in de bibliotheek staat: behandelen als last,
        // precies zoals de app het vóór dit alles deed.
        #expect(LoadStyle(type: nil) == .external)
        #expect(LoadStyle(type: "") == .external)
    }

    // MARK: - Records

    @Test("Records blijven op het gelogde gewicht, behalve bij assisted")
    func recordBasis() {
        #expect(recordLoad(kg: 60, bodyweight: 80, style: .external) == 60)
        #expect(recordLoad(kg: 10, bodyweight: 80, style: .bodyweight) == 10)
        #expect(recordLoad(kg: 20, bodyweight: 80, style: .assisted) == 60)
    }

    /// De kern van de zaak: 40 kg hulp is een zwaardere set dan 50 kg hulp, dus het
    /// geschatte 1RM hoort omhoog te gaan als de hulp omlaag gaat.
    @Test("Minder hulp is een hoger record")
    func minderHulpIsBeter() {
        let veelHulp = epley(recordLoad(kg: 50, bodyweight: 80, style: .assisted), 8)
        let weinigHulp = epley(recordLoad(kg: 40, bodyweight: 80, style: .assisted), 8)
        #expect(weinigHulp > veelHulp)
    }

    /// En de andere as: bij gelijke hulp is meer reps beter. Deze twee samen zijn precies
    /// wat een negatief opgeslagen gewicht níet zou geven.
    @Test("Meer reps bij gelijke hulp is ook een hoger record")
    func meerRepsIsBeter() {
        let acht = epley(recordLoad(kg: 40, bodyweight: 80, style: .assisted), 8)
        let twaalf = epley(recordLoad(kg: 40, bodyweight: 80, style: .assisted), 12)
        #expect(twaalf > acht)
    }
}
