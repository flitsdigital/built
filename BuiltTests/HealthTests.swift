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

    /// Stappen en hartslag komen uit Health, dus die mag Health bijwerken. Je slaaptijden
    /// zijn wat jij zei dat ze waren.
    @Test("Health vult aan, en wist nooit wat er staat")
    func healthVultAan() {
        let day = DayHabits(date: date(2, 12))
        day.apply(steps: 9321, restingHR: 54, hrv: 42,
                  night: HealthService.Night(bed: date(1, 23), wake: date(2, 7)))
        #expect(day.steps == 9321)
        #expect(day.restingHR == 54)
        #expect(day.bedTime == date(1, 23))
        #expect(day.sleptEnough)

        // Niets te melden vanuit Health → laat staan wat er staat.
        day.apply(steps: nil, restingHR: nil, hrv: nil, night: nil)
        #expect(day.steps == 9321)
        #expect(day.hrvMs == 42)
    }

    @Test("Je eigen slaaptijden winnen van Health")
    func handmatigWint() {
        let day = DayHabits(date: date(2, 12))
        day.bedTime = date(1, 22, 30)
        day.wakeTime = date(2, 6, 0)
        day.apply(steps: nil, restingHR: nil, hrv: nil,
                  night: HealthService.Night(bed: date(1, 23), wake: date(2, 7)))
        #expect(day.bedTime == date(1, 22, 30))
        #expect(day.wakeTime == date(2, 6, 0))
    }
}
