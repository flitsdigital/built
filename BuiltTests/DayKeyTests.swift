import Foundation
import SwiftData
import Testing
@testable import Built

/// `dayKey` verving `Calendar.isDate(_:inSameDayAs:)` om snelheidsredenen. Het rekent zelf
/// met de GMT-offset, dus het staat of valt met de twee dagen per jaar waarop die offset
/// verspringt: één dag van 23 uur en één van 25.
@Suite("Dagsleutel")
struct DayKeyTests {
    /// De trage referentie die `dayKey` vervangt: het aantal kalenderdagen sinds 1-1-2001.
    func viaKalender(_ date: Date) -> Int {
        let start = nlCalendar.startOfDay(for: nlDate(2001, 1, 1))
        return nlCalendar.dateComponents([.day], from: start,
                                         to: nlCalendar.startOfDay(for: date)).day!
    }

    /// Alle momenten in een venster, met een vaste stap — ook de uren die door DST
    /// verdwijnen of dubbel voorkomen.
    func momenten(van start: Date, tot eind: Date, stap: TimeInterval = 900) -> [Date] {
        var out: [Date] = []
        var t = start
        while t < eind {
            out.append(t)
            t.addTimeInterval(stap)
        }
        return out
    }

    @Test("Dezelfde lokale dag geeft dezelfde sleutel")
    func zelfdeDag() {
        let vroeg = nlDate(2025, 6, 2, 0, 0)
        let laat = nlDate(2025, 6, 2, 23, 59)
        #expect(dayKey(vroeg) == dayKey(laat))
        #expect(dayKey(nlDate(2025, 6, 1, 23, 59)) != dayKey(vroeg))
        #expect(dayKey(nlDate(2025, 6, 3, 0, 0)) != dayKey(laat))
    }

    @Test("Opeenvolgende dagen geven opeenvolgende gehele getallen")
    func opeenvolgend() {
        // Een heel jaar, dus inclusief beide overgangen én een schrikkeldag-vrij stuk.
        let start = nlDate(2024, 1, 1)
        let eerste = dayKey(start)
        for n in 0..<420 {
            let dag = nlCalendar.date(byAdding: .day, value: n, to: start)!
            #expect(dayKey(dag) == eerste + n)
        }
    }

    @Test("Sleutel komt overeen met de kalender")
    func zelfdeAlsKalender() {
        for datum in [nlDate(2001, 1, 1, 0, 1), nlDate(2001, 1, 1, 23, 59), nlDate(2020, 2, 29),
                      nlDate(2025, 6, 2), nlDate(2030, 12, 31, 23, 59)] {
            #expect(dayKey(datum) == viaKalender(datum))
        }
    }

    @Test("Zomertijd ingaan: de dag van 23 uur blijft één dag")
    func zomertijd() {
        // Laatste zondag van maart 2025: om 02:00 springt de klok naar 03:00.
        let dag = nlDate(2025, 3, 30, 12, 0)
        #expect(nlCalendar.component(.weekday, from: dag) == 1)
        #expect(TimeZone.autoupdatingCurrent.secondsFromGMT(for: nlDate(2025, 3, 30, 0, 30)) == 3600)
        #expect(TimeZone.autoupdatingCurrent.secondsFromGMT(for: nlDate(2025, 3, 30, 23, 30)) == 7200)

        let sleutel = dayKey(dag)
        #expect(dayKey(nlDate(2025, 3, 30, 0, 30)) == sleutel)   // vóór de sprong
        #expect(dayKey(nlDate(2025, 3, 30, 23, 30)) == sleutel)  // erna
        #expect(dayKey(nlDate(2025, 3, 29, 23, 30)) == sleutel - 1)
        #expect(dayKey(nlDate(2025, 3, 31, 0, 30)) == sleutel + 1)

        for moment in momenten(van: nlDate(2025, 3, 28, 0, 0), tot: nlDate(2025, 4, 2, 0, 0)) {
            #expect(dayKey(moment) == viaKalender(moment))
        }
    }

    @Test("Wintertijd ingaan: de dag van 25 uur blijft één dag")
    func wintertijd() {
        // Laatste zondag van oktober 2025: om 03:00 gaat de klok terug naar 02:00, dus
        // 02:30 bestaat twee keer — met verschillende GMT-offset.
        let dag = nlDate(2025, 10, 26, 12, 0)
        #expect(nlCalendar.component(.weekday, from: dag) == 1)
        #expect(TimeZone.autoupdatingCurrent.secondsFromGMT(for: nlDate(2025, 10, 26, 0, 30)) == 7200)
        #expect(TimeZone.autoupdatingCurrent.secondsFromGMT(for: nlDate(2025, 10, 26, 23, 30)) == 3600)

        let sleutel = dayKey(dag)
        #expect(dayKey(nlDate(2025, 10, 26, 0, 30)) == sleutel)
        #expect(dayKey(nlDate(2025, 10, 26, 23, 30)) == sleutel)
        // De twee 02:30's liggen een uur uit elkaar maar op dezelfde dag.
        let eersteHalfDrie = nlDate(2025, 10, 26, 2, 30)
        #expect(dayKey(eersteHalfDrie) == sleutel)
        #expect(dayKey(eersteHalfDrie.addingTimeInterval(3600)) == sleutel)
        #expect(dayKey(nlDate(2025, 10, 25, 23, 30)) == sleutel - 1)
        #expect(dayKey(nlDate(2025, 10, 27, 0, 30)) == sleutel + 1)

        for moment in momenten(van: nlDate(2025, 10, 24, 0, 0), tot: nlDate(2025, 10, 29, 0, 0)) {
            #expect(dayKey(moment) == viaKalender(moment))
        }
    }

    @Test("Middernacht hoort bij de nieuwe dag, de seconde ervoor bij de oude")
    func randVanDeDag() {
        let middernacht = nlCalendar.startOfDay(for: nlDate(2025, 6, 2))
        #expect(dayKey(middernacht) == viaKalender(middernacht))
        #expect(dayKey(middernacht.addingTimeInterval(-1)) == dayKey(middernacht) - 1)
    }
}

/// Het gemiddelde en de trend hangen aan `dayKey(.now)`: een venster van dagen terug.
/// Als dat venster één dag verschuift, gaat de hele trendgrafiek er anders uitzien.
@Suite("Gewichtstrend")
struct WeightTrendTests {
    let context: ModelContext

    init() throws {
        context = try memoryContext()
    }

    /// Wegingen op "n dagen geleden", oplopend op datum zoals de app ze aanlevert.
    func wegingen(_ kgPerDagTerug: [Int: Double]) -> [WeightEntry] {
        let oplopend = kgPerDagTerug.sorted { $0.key > $1.key }
        return store(oplopend.map { WeightEntry(date: daysAgo($0.key), kg: $0.value) }, in: context)
    }

    @Test("Gemiddelde over het venster")
    func gemiddelde() throws {
        let week = wegingen([0: 80, 1: 81, 2: 82, 3: 83, 4: 84, 5: 85, 6: 86])
        let gemiddeld = try #require(week.average(daysBack: 0..<7))
        #expect(abs(gemiddeld - 83) < 1e-9)
    }

    @Test("Wegingen buiten het venster tellen niet mee")
    func buitenVenster() throws {
        let alles = wegingen([0: 80, 1: 80, 7: 100, 8: 100])
        let dezeWeek = try #require(alles.average(daysBack: 0..<7))
        let vorigeWeek = try #require(alles.average(daysBack: 7..<14))
        #expect(abs(dezeWeek - 80) < 1e-9)
        #expect(abs(vorigeWeek - 100) < 1e-9)
    }

    @Test("Een toekomstige weging valt buiten het venster")
    func toekomst() throws {
        let alles = wegingen([-1: 200, 0: 80, 1: 80])
        let dezeWeek = try #require(alles.average(daysBack: 0..<7))
        #expect(abs(dezeWeek - 80) < 1e-9)
    }

    @Test("Leeg venster geeft nil in plaats van 0")
    func leegVenster() {
        #expect([WeightEntry]().average(daysBack: 0..<7) == nil)
        #expect(wegingen([10: 80]).average(daysBack: 0..<7) == nil)
    }

    @Test("Trend is deze week min vorige week")
    func trend() throws {
        var dagen: [Int: Double] = [:]
        for n in 0..<7 { dagen[n] = 81 }
        for n in 7..<14 { dagen[n] = 80 }
        let trend = try #require(wegingen(dagen).trendPerWeek)
        #expect(abs(trend - 1) < 1e-9)
    }

    @Test("Afvallen geeft een negatieve trend")
    func trendOmlaag() throws {
        var dagen: [Int: Double] = [:]
        for n in 0..<7 { dagen[n] = 79 }
        for n in 7..<14 { dagen[n] = 80 }
        let trend = try #require(wegingen(dagen).trendPerWeek)
        #expect(abs(trend + 1) < 1e-9)
    }

    @Test("Zonder vorige week is er geen trend")
    func geenTrend() {
        #expect(wegingen([0: 80, 1: 80]).trendPerWeek == nil)
        #expect(wegingen([7: 80, 8: 80]).trendPerWeek == nil)
    }
}
