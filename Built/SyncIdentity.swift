import Foundation
import SwiftData

/// Alles rond de identiteit van gesynchroniseerde rijen: het eenmalig uitdelen van
/// `syncID` aan rijen van vóór deze versie, en verwijderen mét spoor.
enum SyncIdentity {

    // MARK: - Backfill

    private static let doneKey = "syncIdentityBackfilled"

    /// Bestaande rijen komen uit de lichtgewicht migratie met `UUID.zero`. Eén pass bij de
    /// eerste start erna deelt echte id's uit.
    ///
    /// De vlag in UserDefaults is er niet uit zuinigheid maar omdat dit anders bij élke
    /// start twaalf volledige tabellen zou scannen om niets te vinden.
    @MainActor
    static func backfill(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        var touched = false
        touched = assign(WeightEntry.self, context) || touched
        touched = assign(ProteinEntry.self, context) || touched
        touched = assign(SetEntry.self, context) || touched
        touched = assign(DayHabits.self, context) || touched
        touched = assign(Routine.self, context) || touched
        touched = assign(Meal.self, context) || touched
        touched = assign(FoodProduct.self, context) || touched
        touched = assign(Exercise.self, context) || touched
        touched = assign(Scale.self, context) || touched
        touched = assign(CustomHabit.self, context) || touched
        touched = assign(HabitLog.self, context) || touched
        if touched { try? context.save() }
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Geen `#Predicate` op `syncID`: dat zou over een generieke `SyncedRecord` niet naar
    /// SQL vertalen. Dit draait één keer, dus een scan mag.
    @MainActor
    private static func assign<T: SyncedRecord>(_ type: T.Type, _ context: ModelContext) -> Bool {
        guard let rows = try? context.fetch(FetchDescriptor<T>()) else { return false }
        var touched = false
        for row in rows where row.syncID == .zero {
            row.syncID = UUID()
            touched = true
        }
        return touched
    }
}

// MARK: - Verwijderen met spoor

extension ModelContext {
    /// Verwijdert een gesynchroniseerde rij en laat een tombstone achter voor de server.
    ///
    /// Zonder tombstone is een gewiste rij op de server niet te onderscheiden van een rij
    /// die nooit bestaan heeft: een delta-push noemt hem niet, dus zou hij blijven staan —
    /// en bij de volgende pull weer terugkomen.
    ///
    /// Lokaal wordt de rij écht verwijderd. Een soft-delete zou betekenen dat elke `@Query`
    /// in de app op `deletedAt == nil` moet filteren, en één vergeten filter laat gewiste
    /// data terugkomen in de UI. Het spoor hoort bij de sync, niet bij het model.
    @MainActor
    func deleteSynced<T: SyncedRecord>(_ model: T) {
        // Zonder id heeft de server 'm nooit onder dit id gezien; dan valt er niets te
        // markeren en ruimt een volledige push het op.
        if model.syncID != .zero {
            Sync.recordDeletion(table: T.syncTable, syncID: model.syncID)
        }
        delete(model)
    }
}
