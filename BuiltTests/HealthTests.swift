import Foundation
import Testing
@testable import Built

/// Health levert slaap als losse blokken (licht, diep, REM, wakker tussendoor), soms
/// tientallen per nacht. De app wil er één bedtijd en één opstaantijd uit.
@Suite("Slaap uit Health")
@MainActor
struct HealthTests {

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    @Test("Losse blokken worden één nacht")
    func blokkenVallenSamen() {
        let nights = HealthService.nights(fromAsleepBlocks: [
            (start: date(1, 23, 10), end: date(2, 1, 30)),
            (start: date(2, 1, 45), end: date(2, 4, 0)),
            (start: date(2, 4, 20), end: date(2, 7, 15)),
        ])
        #expect(nights.count == 1)
        let night = nights[Calendar.current.startOfDay(for: date(2, 7))]
        #expect(night?.bed == date(1, 23, 10))
        #expect(night?.wake == date(2, 7, 15))
    }

    /// De nacht hoort bij de ochtend waarop je wakker werd, niet bij de avond ervoor —
    /// anders staat je slaap op de verkeerde dag in het logboek.
    @Test("Twee nachten blijven twee dagen")
    func nachtenPerOchtend() {
        let nights = HealthService.nights(fromAsleepBlocks: [
            (start: date(1, 23, 0), end: date(2, 7, 0)),
            (start: date(2, 23, 30), end: date(3, 6, 30)),
        ])
        #expect(nights.count == 2)
        #expect(nights[Calendar.current.startOfDay(for: date(2, 7))]?.wake == date(2, 7, 0))
        #expect(nights[Calendar.current.startOfDay(for: date(3, 6))]?.bed == date(2, 23, 30))
    }

    /// shortcut in `nights`: alles wat ná het middaguur eindigt is een dutje en telt niet
    /// mee. Zonder die grens rekt een dutje van 15:00 je nacht op tot vijftien uur.
    @Test("Een middagdutje rekt de nacht niet op")
    func dutjeTeltNietMee() {
        let nights = HealthService.nights(fromAsleepBlocks: [
            (start: date(2, 23, 0), end: date(3, 7, 0)),
            (start: date(3, 14, 0), end: date(3, 15, 0)),
        ])
        #expect(nights.count == 1)
        #expect(nights[Calendar.current.startOfDay(for: date(3, 7))]?.wake == date(3, 7, 0))
    }
}
