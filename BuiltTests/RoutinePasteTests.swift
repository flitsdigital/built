import Foundation
import Testing
@testable import Built

// MARK: - Een routine lezen uit platte tekst
//
// De catalogus is hier expres klein: wat telt is welke regel een oefening wordt, welke
// naam eruit komt en wat er met de rest gebeurt.

private let catalogus = ["Bench Press", "Incline Dumbbell Press", "Chest Fly",
                         "Squat", "Barbell Row", "Loopband"]

@Test("Het voorbeeld uit het issue: kop, drie oefeningen, doelen")
func plaktVoorbeeld() {
    let parsed = RoutineText.parse("""
    Push A
    Bankdrukken 3x8
    Incline dumbbell press 3x10
    Kabel fly 2x15
    """, catalogue: catalogus)

    #expect(parsed.name == "Push A")
    #expect(parsed.lines.count == 3)
    #expect(parsed.unrecognized.isEmpty)
    #expect(parsed.lines.map(\.target) == [[3, 8], [3, 10], [2, 15]])
    // Hoofdletters doen er niet toe: dit is de oefening die al in de catalogus staat.
    #expect(parsed.lines[1].candidates == ["Incline Dumbbell Press"])
    #expect(parsed.lines[1].exact)
    // Bankdrukken kent de catalogus niet — dat wordt straks een nieuwe oefening.
    #expect(parsed.lines[0].candidates.isEmpty)
    #expect(parsed.lines[0].name == "Bankdrukken")
}

@Test("Een bekende naam zonder doel is ook een oefening")
func naamZonderDoel() {
    let parsed = RoutineText.parse("Squat\nLoopband", catalogue: catalogus)
    #expect(parsed.lines.map(\.name) == ["Squat", "Loopband"])
    #expect(parsed.lines.compactMap(\.target).isEmpty)
    #expect(parsed.name.isEmpty)
}

@Test("Opsommingstekens, nummers en scheidingstekens gaan eraf")
func opsomming() {
    let parsed = RoutineText.parse("""
    - Squat 5x5
    1. Barbell Row — 4x10
    • Chest Fly: 3 x 12
    """, catalogue: catalogus)
    #expect(parsed.lines.map(\.name) == ["Squat", "Barbell Row", "Chest Fly"])
    #expect(parsed.lines.map(\.target) == [[5, 5], [4, 10], [3, 12]])
    #expect(parsed.lines.map(\.exact) == [true, true, true])
}

@Test("Wat geen oefening is blijft staan, en verdwijnt niet stil")
func onherkendBlijftStaan() {
    let parsed = RoutineText.parse("""
    Leg day
    Squat 5x5
    Rust twee minuten tussen de sets
    """, catalogue: catalogus)
    #expect(parsed.name == "Leg day")
    #expect(parsed.lines.count == 1)
    #expect(parsed.unrecognized == ["Rust twee minuten tussen de sets"])
}

@Test("Bij twijfel meerdere kandidaten, en geen exacte")
func twijfelGeeftKeuze() {
    let parsed = RoutineText.parse("press 3x10", catalogue: catalogus)
    #expect(parsed.lines.count == 1)
    // Twee oefeningen heten zo; de kortste staat vooraan, want die scheelt het minst
    // met wat er geplakt is. Kiezen doet de gebruiker in de preview.
    #expect(parsed.lines[0].candidates == ["Bench Press", "Incline Dumbbell Press"])
    #expect(!parsed.lines[0].exact)
}

@Test("Accenten en leestekens maken geen tweede oefening")
func accentenTellenNiet() {
    #expect(RoutineText.match("bench-press", in: catalogus) == ["Bench Press"])
    #expect(RoutineText.match("Squát", in: catalogus) == ["Squat"])
    #expect(RoutineText.match("Deadlift", in: catalogus).isEmpty)
}

@Test("Een doel vooraan hoort ook bij de naam erachter")
func doelVoorop() {
    let parsed = RoutineText.parse("3x8 Squat", catalogue: catalogus)
    #expect(parsed.lines.map(\.name) == ["Squat"])
    #expect(parsed.lines[0].target == [3, 8])
}

@Test("Lege regels tellen niet mee")
func legeRegels() {
    let parsed = RoutineText.parse("\n\nSquat 3x8\n\n", catalogue: catalogus)
    #expect(parsed.lines.count == 1)
    #expect(parsed.unrecognized.isEmpty)
    #expect(parsed.name.isEmpty)
}
