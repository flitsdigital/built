import AppIntents
import ActivityKit
import Foundation
import UserNotifications

/// De "rust voorbij"-melding. Staat hier en niet bij `Notifier`, want dit bestand deelt
/// de app met de widget-extensie: de knoppen op het lockscreen moeten de melding
/// verzetten zonder dat de app draait. Stond er daarom twee keer, met andere tekst.
enum RestNotification {
    private static let id = "rest"

    static func schedule(at end: Date) {
        cancel()
        let interval = end.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rust voorbij 💪"
        content.body = "Volgende set!"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content,
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// Knoppen in de Live Activity (+15s / Skip). Draait in het app-proces, ook als de
/// app op de achtergrond staat: werkt de activity en de "rust klaar"-melding bij, en
/// laat een marker achter in de app-group zodat de app z'n eigen timer reconcilet.
struct RestControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Rusttimer"

    @Parameter(title: "Actie")
    var action: String

    init() {}
    init(action: String) { self.action = action }

    private static let appGroup = "group.com.jordiklavers.Built"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: Self.appGroup)
        guard let activity = Activity<WorkoutActivity>.activities.first else { return .result() }
        var state = activity.content.state

        if action == "extend", let end = state.restEndsAt {
            let newEnd = end.addingTimeInterval(15)
            state.restEndsAt = newEnd
            await activity.update(ActivityContent(state: state, staleDate: nil))
            RestNotification.schedule(at: newEnd)
            defaults?.set(newEnd.timeIntervalSinceReferenceDate, forKey: "restOverride")
        } else {
            state.restEndsAt = nil
            state.restStartedAt = nil
            await activity.update(ActivityContent(state: state, staleDate: nil))
            RestNotification.cancel()
            defaults?.set(0, forKey: "restOverride")
        }
        return .result()
    }
}
