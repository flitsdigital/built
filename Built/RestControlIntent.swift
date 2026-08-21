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

/// Knoppen in de Live Activity (Set klaar / +15s / Skip). Draait in het app-proces, ook als
/// de app op de achtergrond staat: werkt de activity en de "rust klaar"-melding bij, en
/// laat een marker achter in de app-group zodat de app z'n eigen timer reconcilet.
struct RestControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Training"

    @Parameter(title: "Actie")
    var action: String

    init() {}
    init(action: String) { self.action = action }

    private static let appGroup = "group.com.jordiklavers.Built"
    /// Hoeveel sets er vanaf het lockscreen klaargemeld zijn sinds de app laatst keek.
    /// Een teller en geen vlag: je kunt drie sets doen zonder je telefoon te ontgrendelen.
    static let setsDoneKey = "setsDoneOnLock"
    /// Bij welke oefening die sets horen — de oefening die op dat moment op het lockscreen stond.
    static let setsDoneExerciseKey = "setsDoneOnLockExercise"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: Self.appGroup)
        guard let activity = Activity<WorkoutActivity>.activities.first else { return .result() }
        var state = activity.content.state

        switch action {
        case "extend":
            guard let end = state.restEndsAt else { break }
            let newEnd = end.addingTimeInterval(15)
            state.restEndsAt = newEnd
            await activity.update(ActivityContent(state: state, staleDate: nil))
            RestNotification.schedule(at: newEnd)
            defaults?.set(newEnd.timeIntervalSinceReferenceDate, forKey: "restOverride")

        case "done":
            // De extensie deelt geen ModelContext met de app en vinkt hier dus niets af:
            // ze telt alleen dat er een set klaar is. De lopende training in de app blijft
            // de bron van waarheid en maakt er bij terugkeer de echte set van.
            guard state.setsLeft > 0 else { break }
            state.setsDone += 1
            defaults?.set((defaults?.integer(forKey: Self.setsDoneKey) ?? 0) + 1, forKey: Self.setsDoneKey)
            defaults?.set(state.exercise, forKey: Self.setsDoneExerciseKey)
            if state.restSeconds > 0 {
                let end = Date.now.addingTimeInterval(Double(state.restSeconds))
                state.restStartedAt = .now
                state.restEndsAt = end
                RestNotification.schedule(at: end)
                defaults?.set(end.timeIntervalSinceReferenceDate, forKey: "restOverride")
            }
            await activity.update(ActivityContent(state: state, staleDate: nil))

        default: // skip
            state.restEndsAt = nil
            state.restStartedAt = nil
            await activity.update(ActivityContent(state: state, staleDate: nil))
            RestNotification.cancel()
            defaults?.set(0, forKey: "restOverride")
        }
        return .result()
    }
}
