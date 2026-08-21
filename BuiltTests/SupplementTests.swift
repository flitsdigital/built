import Foundation
import SwiftData
import Testing
@testable import Built

/// Een eigen habit met dosering is een supplement. Het enige echte rekenwerk daarin is de
/// voorraad, en die zit in `setHabit` omdat het dashboard én de dagdetails afvinken — een
/// tweede kopie van die regel telt gegarandeerd een keer verkeerd af.
@MainActor
@Suite("Supplementen")
struct SupplementTests {
    let context: ModelContext
    /// Vaste dag, zodat niets van de kalender van vandaag afhangt.
    let dag = nlDate(2025, 6, 2)

    init() throws {
        context = try memoryContext()
    }

    func supplement(_ stock: Int?) -> CustomHabit {
        let habit = CustomHabit(name: "Creatine")
        habit.dose = "5 g"
        habit.stockLeft = stock
        context.insert(habit)
        return habit
    }

    var logs: [HabitLog] { (try? context.fetch(FetchDescriptor<HabitLog>())) ?? [] }

    @Test("Afvinken haalt één dosis van de voorraad")
    func afvinken() {
        let habit = supplement(12)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        #expect(logs.count == 1)
        #expect(habit.stockLeft == 11)
    }

    @Test("Vinkje weghalen zet de dosis terug")
    func uitvinken() {
        let habit = supplement(12)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        context.setHabit(habit, on: dag, done: false, logs: logs)
        #expect(logs.isEmpty)
        #expect(habit.stockLeft == 12)
    }

    @Test("Twee keer afvinken op dezelfde dag kost één dosis")
    func tweeKeerZelfdeDag() {
        let habit = supplement(12)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        #expect(logs.count == 1)
        #expect(habit.stockLeft == 11)
    }

    @Test("Zonder voorraad blijft de teller leeg")
    func geenVoorraad() {
        let habit = supplement(nil)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        #expect(logs.count == 1)
        #expect(habit.stockLeft == nil)
        #expect(habit.detail == "5 g")
    }

    @Test("De laatste dosis brengt de voorraad op nul, niet eronder")
    func laatsteDosis() {
        let habit = supplement(0)
        context.setHabit(habit, on: dag, done: true, logs: logs)
        #expect(habit.stockLeft == 0)
        #expect(habit.detail == "5 g · voorraad op")
    }

    @Test("De regel onder de naam telt de dagen die je nog vooruit kunt")
    func detailregel() {
        #expect(supplement(12).detail == "5 g · nog 12 dagen")
        #expect(supplement(1).detail == "5 g · nog 1 dag")
        let habit = supplement(nil)
        habit.dose = ""
        #expect(habit.detail.isEmpty)
    }

    @Test("Bijna op vanaf een week vooruit")
    func bijnaOp() {
        #expect(supplement(8).stockLow == false)
        #expect(supplement(7).stockLow)
        #expect(supplement(0).stockLow)
        // Geen voorraad bijhouden is nooit een waarschuwing.
        #expect(supplement(nil).stockLow == false)
    }
}
