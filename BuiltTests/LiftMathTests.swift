import Foundation
import Testing
@testable import Built

/// Het geschatte 1RM bepaalt PR's en de "vorige keer"-tip. Fout = een PR die niet bestaat.
@Suite("Epley 1RM")
struct EpleyTests {
    @Test("Eén rep of minder is het gewicht zelf")
    func eenRep() {
        #expect(epley(100, 1) == 100)
        #expect(epley(100, 0) == 100)   // lege set
        #expect(epley(100, -3) == 100)  // onmogelijke invoer mag niets raars doen
    }

    @Test("Meer reps is een hogere schatting")
    func formule() {
        #expect(abs(epley(60, 10) - 80) < 1e-9)    // 60 × (1 + 10/30)
        #expect(abs(epley(100, 30) - 200) < 1e-9)  // 30 reps = dubbel
        #expect(abs(epley(100, 5) - 116.6666667) < 1e-6)
    }

    @Test("Monotoon oplopend in reps")
    func monotoon() {
        for reps in 2...20 {
            #expect(epley(100, reps) > epley(100, reps - 1))
        }
    }

    @Test("Zonder gewicht is de schatting 0")
    func geenGewicht() {
        #expect(epley(0, 10) == 0)
    }
}

/// De schijvenberekening staat naast de setinvoer: als die te veel schijven noemt, sta je
/// met een te zware stang.
@Suite("Schijven per kant")
struct PlatesTests {
    let denominaties: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]

    @Test("Onder het stanggewicht is er niets te leggen")
    func onderDeStang() {
        #expect(platesPerSide(total: 19) == nil)
        #expect(platesPerSide(total: 0) == nil)
        #expect(platesPerSide(total: 20)?.isEmpty == true) // precies de lege stang
    }

    @Test("Greedy vanaf de zwaarste schijf")
    func greedy() throws {
        let honderd = try #require(platesPerSide(total: 100))
        let zestig = try #require(platesPerSide(total: 60))
        let honderdveertig = try #require(platesPerSide(total: 140))
        #expect(honderd == [25, 15])
        #expect(zestig == [20])
        #expect(honderdveertig == [25, 25, 10])
    }

    @Test("Halve kilo's komen op 1,25 uit ondanks afrondingsfouten")
    func kleineSchijven() throws {
        let tweeenzestigenhalf = try #require(platesPerSide(total: 62.5))
        let tweeenveertigenhalf = try #require(platesPerSide(total: 42.5))
        #expect(tweeenzestigenhalf == [20, 1.25])
        #expect(tweeenveertigenhalf == [10, 1.25])
    }

    @Test("Rest kleiner dan de kleinste schijf vervalt")
    func restVervalt() throws {
        let eenentwintig = try #require(platesPerSide(total: 21))
        #expect(eenentwintig.isEmpty) // 0,5 kg per kant past niet
    }

    @Test("Andere stang werkt hetzelfde")
    func andereStang() throws {
        let vijfenvijftig = try #require(platesPerSide(total: 55, bar: 15))
        #expect(vijfenvijftig == [20])
        #expect(platesPerSide(total: 14, bar: 15) == nil)
    }

    @Test("Het resultaat past altijd op de stang")
    func altijdKloppendeStapel() throws {
        for stap in 0...720 {
            let totaal = 20 + Double(stap) * 0.25
            let schijven = try #require(platesPerSide(total: totaal))
            let rest = totaal - 20 - 2 * schijven.reduce(0, +)
            // De 0,01-marge in de vergelijking mag er hooguit één schijf net overheen duwen.
            #expect(rest > -0.021)
            #expect(rest < 2.5) // wat overblijft haalt geen 1,25 per kant meer
            #expect(schijven == schijven.sorted(by: >))
            #expect(schijven.allSatisfy(denominaties.contains))
        }
    }
}
