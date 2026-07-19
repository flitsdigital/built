import EventKit
import Foundation

/// Weekplanning naar de iOS-agenda. Staat je Google-account onder Instellingen →
/// Agenda, dan landen de events in Google Calendar en synct iOS ze twee kanten op.
@MainActor
enum CalendarSync {
    private static let store = EKEventStore()
    private static let idKey = "calendarEventIDs"

    static func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    /// Idempotent: eerder door Built gemaakte events worden eerst verwijderd,
    /// daarna de komende `weeks` weken opnieuw uit de planning opgebouwd.
    /// Geeft het aantal geplande trainingen terug.
    @discardableResult
    static func sync(profile: Profile, weeks: Int = 4, hour: Int = 18) throws -> Int {
        removeCreated()
        guard let calendar = store.defaultCalendarForNewEvents else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var ids: [String] = []
        for offset in 0..<(weeks * 7) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let routine = profile.plannedRoutine(weekday: cal.component(.weekday, from: day)),
                  let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = "🏋️ \(routine)"
            event.notes = "Built training"
            event.startDate = start
            event.endDate = start.addingTimeInterval(3600)
            try store.save(event, span: .thisEvent)
            if let id = event.eventIdentifier { ids.append(id) }
        }
        UserDefaults.standard.set(ids, forKey: idKey)
        return ids.count
    }

    /// Notitie-stempel waaraan we onze eigen events herkennen — ook op een ander
    /// toestel of na herinstallatie, wanneer de lokale ID-lijst leeg is.
    private static let stamp = "Built training"

    static func removeCreated() {
        // 1) Eerst via de lokaal bewaarde IDs (snel, exacte match).
        for id in UserDefaults.standard.stringArray(forKey: idKey) ?? [] {
            if let event = store.event(withIdentifier: id) {
                try? store.remove(event, span: .thisEvent)
            }
        }
        UserDefaults.standard.removeObject(forKey: idKey)

        // 2) Scan daarnaast een ruim venster op Built-events die we niet lokaal kennen
        //    (na herinstallatie of vanaf een tweede toestel) → geen dubbelingen.
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let end = cal.date(byAdding: .day, value: 366, to: today) else { return }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        for event in store.events(matching: predicate) where event.notes == stamp {
            try? store.remove(event, span: .thisEvent)
        }
    }

    static var hasCreatedEvents: Bool {
        !(UserDefaults.standard.stringArray(forKey: idKey) ?? []).isEmpty
    }
}
