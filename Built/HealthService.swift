import Foundation
import HealthKit
import Observation

/// Stappen uit Health. ponytail: alleen lezen, alleen stappen — zonder Apple Watch
/// is de rest (hartslag, betrouwbare slaap) er toch niet. Health blijft de opslag;
/// we kopiëren niets naar SwiftData.
@MainActor
@Observable
final class HealthService {
    static let shared = HealthService()

    /// Stappen per dag (key = startOfDay), gevuld door `refresh`.
    private(set) var stepsByDay: [Date: Int] = [:]
    private(set) var authorized = false

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var stepType: HKQuantityType { .quantityType(forIdentifier: .stepCount)! }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func steps(on day: Date) -> Int? {
        stepsByDay[Calendar.current.startOfDay(for: day)]
    }

    /// Vraagt toegang en haalt meteen op. Health vertelt niet of je "nee" zei bij lezen
    /// (privacy) — lege data is het enige signaal, daarom geen foutmelding.
    func requestAndRefresh(days: Int = 120) async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType])
            authorized = true
            UserDefaults.standard.set(true, forKey: "healthStepsOn")
            await refresh(days: days)
        } catch {
            authorized = false
        }
    }

    /// Dagtotalen ophalen als de gebruiker Health eerder heeft aangezet.
    func refreshIfEnabled(days: Int = 120) async {
        guard isAvailable, UserDefaults.standard.bool(forKey: "healthStepsOn") else { return }
        authorized = true
        await refresh(days: days)
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: "healthStepsOn")
        authorized = false
        stepsByDay = [:]
    }

    private func refresh(days: Int) async {
        let cal = Calendar.current
        let end = cal.startOfDay(for: .now)
        guard let start = cal.date(byAdding: .day, value: -days, to: end) else { return }

        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(
                type: stepType,
                predicate: HKQuery.predicateForSamples(withStart: start, end: cal.date(byAdding: .day, value: 1, to: end))),
            options: .cumulativeSum,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1))

        guard let result = try? await query.result(for: store) else { return }
        var out: [Date: Int] = [:]
        // tot en met vandaag → bovengrens een dag verder, anders valt vandaag erbuiten
        result.enumerateStatistics(from: start, to: cal.date(byAdding: .day, value: 1, to: end) ?? end) { stats, _ in
            if let sum = stats.sumQuantity()?.doubleValue(for: .count()), sum > 0 {
                out[cal.startOfDay(for: stats.startDate)] = Int(sum)
            }
        }
        stepsByDay = out
    }
}
