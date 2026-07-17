import AppIntents
import ActivityKit
import Foundation
import UserNotifications

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
            rescheduleRest(at: newEnd)
            defaults?.set(newEnd.timeIntervalSinceReferenceDate, forKey: "restOverride")
        } else {
            state.restEndsAt = nil
            state.restStartedAt = nil
            await activity.update(ActivityContent(state: state, staleDate: nil))
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest"])
            defaults?.set(0, forKey: "restOverride")
        }
        return .result()
    }

    private func rescheduleRest(at end: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["rest"])
        let content = UNMutableNotificationContent()
        content.title = "Rust klaar 💪"
        content.body = "Volgende set!"
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(end.timeIntervalSinceNow, 1), repeats: false)
        center.add(UNNotificationRequest(identifier: "rest", content: content, trigger: trigger))
    }
}
