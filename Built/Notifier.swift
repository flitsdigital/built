import Foundation
import SwiftData
import UserNotifications

// Notificatie-motor: bij elke keer dat de app naar de achtergrond gaat worden alle
// meldingen opnieuw gepland op basis van de actuele staat. Stil bij succes: wat al
// gedaan is, geeft geen melding. Vandaag = slimme inhoud; dag +1/+2 = generieke
// fallback zodat een paar dagen niet-openen nog steeds reminders geeft.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    @Published var pendingAction: String?
    var context: ModelContext?

    private let center = UNUserNotificationCenter.current()
    private var cal: Calendar { .current }
    private let managedIDs = ["morning-0", "morning-1", "morning-2",
                              "evening-0", "evening-1", "evening-2",
                              "checkin-0", "checkin-1", "checkin-2",
                              "streak", "review",
                              // elke weekdag kan een trainingsherinnering hebben (eigen trainingsdagen)
                              "week-1", "week-2", "week-3", "week-4", "week-5", "week-6", "week-7"]

    // MARK: - Setup

    func setup() {
        center.delegate = self
        let protein = UNNotificationAction(identifier: "openProtein", title: "Log eiwit", options: [.foreground])
        let creatine = UNNotificationAction(identifier: "creatineDone", title: "Creatine ✓")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "evening", actions: [protein, creatine], intentIdentifiers: []),
        ])
    }

    // MARK: - Instellingen (zelfde keys als @AppStorage in de UI)

    private var d: UserDefaults { .standard }

    private func flag(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    private func time(_ key: String, default def: Int) -> (hour: Int, minute: Int) {
        let m = d.object(forKey: key) as? Int ?? def
        return (m / 60, m % 60)
    }

    // MARK: - Staat

    private struct DayState {
        var proteinRemaining = 0
        var creatineOpen = false
        var weighedToday = false
        var sleepOpen = false
        var trainedToday = false
        var checkedInToday = false
        var tracksFood = true
        var streak = 0
        var perfectToday = false
        var trainingsThisWeek = 0
        var trainingsTarget = 3
        var trainingDays: [Int] = []
        var plannedToday = false
        var schedule: [String: String] = [:]
        var plannedRoutineToday: String?
    }

    private func computeState() -> DayState? {
        guard let context,
              let profile = try? context.fetch(FetchDescriptor<Profile>()).first else { return nil }
        let proteins = (try? context.fetch(FetchDescriptor<ProteinEntry>())) ?? []
        let weights = (try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []
        let habits = (try? context.fetch(FetchDescriptor<DayHabits>())) ?? []
        let sets = (try? context.fetch(FetchDescriptor<SetEntry>())) ?? []

        var s = DayState()
        let todayProtein = proteins.filter { cal.isDateInToday($0.date) }.map(\.grams).reduce(0, +)
        s.tracksFood = profile.tracksFood
        s.proteinRemaining = profile.tracksFood ? max(profile.proteinTarget - todayProtein, 0) : 0
        let todayHabits = habits.first { cal.isDateInToday($0.date) }
        s.checkedInToday = todayHabits?.checkedIn == true
        s.creatineOpen = profile.tracksCreatine && todayHabits?.creatine != true
        s.weighedToday = weights.contains { cal.isDateInToday($0.date) }
        s.sleepOpen = profile.tracksSleep && todayHabits?.sleptEnough != true
        s.trainedToday = sets.contains { cal.isDateInToday($0.date) }
        if let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)) {
            s.trainingsThisWeek = Set(sets.filter { $0.date >= weekStart }.map { cal.startOfDay(for: $0.date) }).count
        }
        s.trainingsTarget = profile.trainingsPerWeek
        s.trainingDays = profile.trainingDays
        s.plannedToday = profile.trainingDays.contains(cal.component(.weekday, from: .now))
        s.schedule = profile.schedule
        s.plannedRoutineToday = profile.plannedRoutine(weekday: cal.component(.weekday, from: .now))
        s.streak = DayCheck.streak(proteins: proteins, weights: weights, habits: habits,
                                   target: profile.proteinTarget,
                                   requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                                   sets: sets, trainingDays: profile.trainingDays, requireFood: profile.tracksFood)
        s.perfectToday = DayCheck.perfect(.now, proteins: proteins, weights: weights, habits: habits,
                                          target: profile.proteinTarget,
                                          requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                                          sets: sets, trainingDays: profile.trainingDays, requireFood: profile.tracksFood)
        return s
    }

    private func openItems(_ s: DayState) -> [String] {
        var items: [String] = []
        if s.proteinRemaining > 0 { items.append("\(s.proteinRemaining) g eiwit") }
        if s.creatineOpen { items.append("creatine") }
        if !s.weighedToday { items.append("wegen") }
        if s.sleepOpen { items.append("slaap afvinken") }
        if s.plannedToday, !s.trainedToday {
            items.append(s.plannedRoutineToday.map { "\($0) trainen" } ?? "trainen")
        }
        return items
    }

    // MARK: - Plannen

    func refresh() {
        center.removePendingNotificationRequests(withIdentifiers: managedIDs)
        let anyEnabled = flag("notifMorningOn", default: false) || flag("notifEveningOn", default: false)
            || flag("notifStreakOn", default: true) || flag("notifWeekOn", default: true)
            || flag("notifReviewOn", default: true) || flag("notifCheckInOn", default: true)
        guard anyEnabled, let state = computeState() else { return }

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            scheduleAll(state)
        }
    }

    private func scheduleAll(_ s: DayState) {
        let today = cal.startOfDay(for: .now)

        if flag("notifMorningOn", default: false) {
            let t = time("notifMorningTime", default: 8 * 60)
            for offset in 0..<3 {
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let fire = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) else { continue }
                if offset == 0, s.weighedToday { continue } // al gewogen → stil
                oneShot(id: "morning-\(offset)", title: "Goedemorgen 💪",
                        body: "Stap even op de weegschaal — 10 seconden werk.",
                        at: fire, action: "weigh")
            }
        }

        if flag("notifEveningOn", default: false) {
            let t = time("notifEveningTime", default: 20 * 60 + 30)
            let open = openItems(s)
            for offset in 0..<3 {
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let fire = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) else { continue }
                if offset == 0, open.isEmpty { continue } // dag is al binnen → stil
                let body = offset == 0
                    ? "Nog te gaan: \(open.joined(separator: ", "))."
                    : "Vink je dag af voor je streak."
                oneShot(id: "evening-\(offset)", title: "Avondcheck 🔥", body: body,
                        at: fire, action: "protein", category: "evening")
            }
        }

        if flag("notifStreakOn", default: true), s.streak >= 3, !s.perfectToday {
            let open = openItems(s)
            if let fire = cal.date(bySettingHour: 21, minute: 30, second: 0, of: today), !open.isEmpty {
                oneShot(id: "streak", title: "🔥 Streak van \(s.streak) dagen in gevaar",
                        body: "Nog te gaan: \(open.joined(separator: ", ")). Paar minuten werk.",
                        at: fire, action: "protein")
            }
        }

        if flag("notifWeekOn", default: true), s.trainingsThisWeek < s.trainingsTarget {
            let remaining = s.trainingsTarget - s.trainingsThisWeek
            let reminderDays = s.trainingDays.isEmpty ? [5, 6] : s.trainingDays // vaste dagen als die er zijn
            for weekday in reminderDays {
                var comps = DateComponents()
                comps.weekday = weekday
                comps.hour = 17
                guard let fire = cal.nextDate(after: .now, matching: comps, matchingPolicy: .nextTime),
                      cal.isDate(fire, equalTo: .now, toGranularity: .weekOfYear) else { continue }
                if s.trainedToday, cal.isDateInToday(fire) { continue }
                let planned = s.schedule[String(weekday)]
                let body = planned.map { "Vandaag staat \($0) gepland — nog \(remaining) van \(s.trainingsTarget) deze week." }
                    ?? "Nog \(remaining) van je \(s.trainingsTarget) trainingen deze week — vanavond eentje?"
                oneShot(id: "week-\(weekday)", title: "Trainingsweek 🏋️",
                        body: body,
                        at: fire, action: "training")
            }
        }

        // Dag-check-in: de melding is wat de data binnenhaalt. Stil als je 'm al invulde.
        if flag("notifCheckInOn", default: true) {
            for offset in 0..<3 {
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let fire = cal.date(bySettingHour: 21, minute: 0, second: 0, of: day) else { continue }
                if offset == 0, s.checkedInToday { continue }
                oneShot(id: "checkin-\(offset)", title: "Hoe was je dag? 📓",
                        body: "Energie, stemming, spierpijn, stress — vier tikken.",
                        at: fire, action: "checkin")
            }
        }

        if flag("notifReviewOn", default: true) {
            let content = UNMutableNotificationContent()
            content.title = "Week Review 📊"
            content.body = "Je weekoverzicht staat klaar — trainingen, eiwit en gewicht."
            content.sound = .default
            content.userInfo = ["action": "review"]
            var comps = DateComponents()
            comps.weekday = 1 // zondag
            comps.hour = 19
            center.add(UNNotificationRequest(identifier: "review", content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        }
    }

    private func oneShot(id: String, title: String, body: String, at date: Date, action: String, category: String? = nil) {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["action": action]
        if let category { content.categoryIdentifier = category }
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    // MARK: - Rust-timer

    func scheduleRest(at end: Date) {
        guard flag("notifRestOn", default: true) else { return }
        cancelRest()
        let interval = end.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rust voorbij 💪"
        content.body = "Volgende set!"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "rest", content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }

    func cancelRest() {
        center.removePendingNotificationRequests(withIdentifiers: ["rest"])
        center.removeDeliveredNotifications(withIdentifiers: ["rest"])
    }

    // MARK: - Acties & delegate

    private func markCreatineDone() {
        guard let context else { return }
        let habits = (try? context.fetch(FetchDescriptor<DayHabits>())) ?? []
        if let today = habits.first(where: { cal.isDateInToday($0.date) }) {
            today.creatine = true
        } else {
            let h = DayHabits()
            h.creatine = true
            context.insert(h)
        }
        try? context.save()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Geen async-variant: UIKit rondt die af op een achtergrond-thread en crasht
        // dan op een main-thread-assert bij het snapshotten (state restoration).
        let action = response.notification.request.content.userInfo["action"] as? String
        let identifier = response.actionIdentifier
        DispatchQueue.main.async {
            switch identifier {
            case "creatineDone":
                Notifier.shared.markCreatineDone()
            case "openProtein":
                Notifier.shared.pendingAction = "protein"
            default:
                Notifier.shared.pendingAction = action
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // In de app dekt de haptic het einde van de rust al — geen dubbele banner
        completionHandler(notification.request.identifier == "rest" ? [] : [.banner, .sound])
    }
}
