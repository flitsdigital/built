import Foundation
import Testing
@testable import Built

/// De gratieperiode is het enige rekenwerk in de vergrendeling, en precies het stukje dat
/// je meteen merkt als het misgaat: te kort en de barcodescanner gooit je uit je eigen
/// app, te lang en het slot stelt niets voor.
@Suite("Vergrendeling")
struct AppLockTests {
    private let weg = Date(timeIntervalSinceReferenceDate: 0)

    @Test("Even weg voor de camera of een deelblad laat je erin")
    func binnenGratie() {
        #expect(AppLock.shouldLock(leftAt: weg, now: weg.addingTimeInterval(5)) == false)
    }

    @Test("Telefoon weggelegd zet het slot erop")
    func buitenGratie() {
        #expect(AppLock.shouldLock(leftAt: weg, now: weg.addingTimeInterval(120)))
    }

    /// Precies op de grens hoort hij dicht te gaan: bij twijfel vergrendelen, niet openlaten.
    @Test("Op de grens gaat hij dicht")
    func opDeGrens() {
        #expect(AppLock.shouldLock(leftAt: weg, now: weg.addingTimeInterval(AppLock.grace)))
    }
}
