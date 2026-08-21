import Foundation
import SwiftData
import Testing
@testable import Built

// MARK: - Vaste tijdzone
//
// `dayKey` leest `TimeZone.autoupdatingCurrent`, de score leest `Calendar.current`: allebei
// volgen ze de tijdzone van het proces. Het testschema zet die via de TZ-variabele op
// Europe/Amsterdam, zodat de DST-tests op elke machine hetzelfde doen. Tijdens de run
// omzetten kan niet: `NSTimeZone.default` verplaatst `Calendar.current` wél maar
// `autoupdatingCurrent` niet, en dan gaan de twee juist uit elkaar lopen.

@Test("Tests draaien in Europe/Amsterdam")
func vasteTijdzone() {
    #expect(TimeZone.autoupdatingCurrent.identifier == "Europe/Amsterdam")
    #expect(Calendar.current.timeZone.identifier == "Europe/Amsterdam")
}

/// Eigen kalender om verwachte uitkomsten mee te bouwen — dan bevestigt een test niet
/// zijn eigen aanname over `Calendar.current`.
let nlCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    return cal
}()

func nlDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    nlCalendar.date(from: DateComponents(year: year, month: month, day: day,
                                         hour: hour, minute: minute))!
}

/// `n` dagen terug, midden op de dag: ver genoeg van middernacht dat een test niet omvalt
/// als hij toevallig om 23:59 draait.
func daysAgo(_ n: Int) -> Date {
    let start = nlCalendar.date(byAdding: .day, value: -n, to: nlCalendar.startOfDay(for: .now))!
    return nlCalendar.date(byAdding: .hour, value: 12, to: start)!
}

/// In-memory store: de modellen gedragen zich als in de app zonder de echte database te raken.
///
/// Alle gesynchroniseerde modellen zitten erin, ook de modellen die de meeste tests niet
/// gebruiken: `Sync.collect` fetcht ze allemaal en gooit op een type dat de container
/// niet kent.
func memoryContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Profile.self, WeightEntry.self, ProteinEntry.self, SetEntry.self,
        DayHabits.self, HabitLog.self, CustomHabit.self, FoodProduct.self,
        Routine.self, Meal.self, Exercise.self, Scale.self, SetEdit.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ModelContext(container)
}

/// Alles wat een test bouwt gaat ook echt door de store, zodat de modellen zich net zo
/// gedragen als in de app.
@discardableResult
func store<T: PersistentModel>(_ models: [T], in context: ModelContext) -> [T] {
    for model in models { context.insert(model) }
    return models
}
