import Foundation
import Testing
@testable import Built

/// Mijlpalen vieren het jaar, niet de dag. Verkeerd geteld is erger dan niet gevierd:
/// een "100e training" die er in werkelijkheid 60 blijken te zijn devalueert de rest.
@Suite("Mijlpalen")
struct MilestoneTests {

    /// `n` losse trainingen, elk één set van 20 kg × 5 — samen ruim onder elke
    /// volumedrempel, zodat een test over tellingen niet per ongeluk over volume gaat.
    @MainActor private func trainingen(_ n: Int) -> [SetEntry] {
        (0..<n).map { i in
            SetEntry(date: daysAgo(i % 5), exercise: "Bench Press", weightKg: 20, reps: 5,
                     workoutID: UUID())
        }
    }

    @Test("Onder de eerste drempel valt er niets te vieren")
    @MainActor func nogNiets() {
        #expect(Milestones.reached([]).isEmpty)
        #expect(Milestones.reached(trainingen(9)).isEmpty)
    }

    @Test("Per soort alleen de hoogste gehaalde drempel")
    @MainActor func hoogsteDrempel() {
        let ids = Milestones.reached(trainingen(120)).map(\.id)
        #expect(ids.contains("trainingen-100"))
        #expect(!ids.contains("trainingen-50"))  // niet ook alles eronder
        #expect(!ids.contains("trainingen-250")) // en niet vooruitlopen
    }

    /// Trainingen worden per sessie geteld, niet per dag: wie 's ochtends en 's avonds
    /// gaat, staat anders eeuwig op de helft.
    @Test("Twee trainingen op één dag tellen als twee")
    @MainActor func tweePerDag() {
        var sets = trainingen(9)
        sets.append(SetEntry(date: daysAgo(0), exercise: "Squat", weightKg: 20, reps: 5,
                             workoutID: UUID()))
        #expect(Milestones.reached(sets).map(\.id).contains("trainingen-10"))
    }

    @Test("Volume telt gewicht × reps van alle sets bij elkaar")
    @MainActor func volume() {
        // 100 × 100 kg × 10 reps = precies 100.000 kg: de drempel telt mee, niet pas erboven.
        let sets = (0..<100).map { _ in
            SetEntry(date: daysAgo(0), exercise: "Deadlift", weightKg: 100, reps: 10,
                     workoutID: UUID())
        }
        let ids = Milestones.reached(sets).map(\.id)
        #expect(ids.contains("volume-100000"))
        #expect(!ids.contains("volume-250000"))
    }

    /// Een week is pas voorbij als hij voorbij is — anders zou de reeks elke maandag
    /// breken, precies zoals de dagstreak vandaag nog open laat staan.
    @Test("De lopende week mag nog leeg zijn")
    @MainActor func lopendeWeek() {
        let now = nlDate(2026, 8, 20)
        let dagen = (1...4).compactMap { nlCalendar.date(byAdding: .weekOfYear, value: -$0, to: now) }
        #expect(Milestones.weekStreak(dagen, now: now) == 4)
    }

    @Test("Een week zonder training breekt de reeks")
    @MainActor func gemisteWeek() {
        let now = nlDate(2026, 8, 20)
        var dagen = (0...2).compactMap { nlCalendar.date(byAdding: .weekOfYear, value: -$0, to: now) }
        // Week 3 overgeslagen; wat daarvóór staat telt niet meer mee.
        dagen += (4...6).compactMap { nlCalendar.date(byAdding: .weekOfYear, value: -$0, to: now) }
        #expect(Milestones.weekStreak(dagen, now: now) == 3)
    }

    @Test("Een jaar op rij heeft een eigen titel")
    @MainActor func jaarTitel() {
        let now = nlDate(2026, 8, 20)
        let sets = (0..<60).compactMap { nlCalendar.date(byAdding: .weekOfYear, value: -$0, to: now) }
            .map { SetEntry(date: $0, exercise: "Row", weightKg: 20, reps: 5, workoutID: UUID()) }
        let jaar = Milestones.reached(sets, now: now).first { $0.id == "weken-52" }
        #expect(jaar?.title == "Een jaar zonder een week over te slaan")
    }
}
