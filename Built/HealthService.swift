import Foundation
import HealthKit
import Observation

/// Wat je bandje (of je telefoon) in Health zet: stappen, slaap, rust-hartslag, HRV, en
/// de hartslag tijdens een training. ponytail: alleen lezen, en Health blijft de opslag —
/// we kopiëren niets naar SwiftData. Enige uitzondering is slaap, want dat ís hier al een
/// habit met een score en een streak; zie `fillSleepFromHealth`.
///
/// Garmins eigen scores (Body Battery, slaapscore, training readiness) schrijft Garmin
/// niet naar Health, dus die staan hier niet en komen hier ook nooit.
@MainActor
@Observable
final class HealthService {
    static let shared = HealthService()

    /// Eén nacht: wanneer je in slaap viel en wanneer je wakker werd.
    struct Night: Equatable {
        let bed: Date
        let wake: Date
    }

    /// Stappen per dag (key = startOfDay), gevuld door `refresh`.
    private(set) var stepsByDay: [Date: Int] = [:]
    /// Nacht per ochtend waarop je wakker werd (key = startOfDay van die ochtend).
    private(set) var sleepByDay: [Date: Night] = [:]
    private(set) var restingHRByDay: [Date: Int] = [:]
    private(set) var hrvByDay: [Date: Int] = [:]
    private(set) var authorized = false

    @ObservationIgnored private let store = HKHealthStore()

    private var stepType: HKQuantityType { .quantityType(forIdentifier: .stepCount)! }
    private var restingHRType: HKQuantityType { .quantityType(forIdentifier: .restingHeartRate)! }
    private var hrvType: HKQuantityType { .quantityType(forIdentifier: .heartRateVariabilitySDNN)! }
    private var heartRateType: HKQuantityType { .quantityType(forIdentifier: .heartRate)! }
    private var sleepType: HKCategoryType { .categoryType(forIdentifier: .sleepAnalysis)! }

    private var readTypes: Set<HKObjectType> {
        [stepType, restingHRType, hrvType, heartRateType, sleepType]
    }

    private var bpm: HKUnit { .count().unitDivided(by: .minute()) }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func steps(on day: Date) -> Int? { stepsByDay[Calendar.current.startOfDay(for: day)] }
    func night(on day: Date) -> Night? { sleepByDay[Calendar.current.startOfDay(for: day)] }
    func restingHR(on day: Date) -> Int? { restingHRByDay[Calendar.current.startOfDay(for: day)] }
    func hrv(on day: Date) -> Int? { hrvByDay[Calendar.current.startOfDay(for: day)] }

    /// Vraagt toegang en haalt meteen op. Health vertelt niet of je "nee" zei bij lezen
    /// (privacy) — lege data is het enige signaal, daarom geen foutmelding.
    func requestAndRefresh(days: Int = 120) async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authorized = true
            UserDefaults.standard.set(true, forKey: Self.onKey)
            await refresh(days: days)
        } catch {
            authorized = false
        }
    }

    /// Ophalen als de gebruiker Health eerder heeft aangezet.
    func refreshIfEnabled(days: Int = 120) async {
        guard isAvailable, UserDefaults.standard.bool(forKey: Self.onKey) else { return }
        authorized = true
        await refresh(days: days)
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.onKey)
        authorized = false
        stepsByDay = [:]
        sleepByDay = [:]
        restingHRByDay = [:]
        hrvByDay = [:]
    }

    /// De sleutel heet nog "stappen" van toen dit alleen stappen las. Hernoemen zou
    /// iedereen die Health aan heeft staan opnieuw om toestemming vragen.
    private static let onKey = "healthStepsOn"

    private func refresh(days: Int) async {
        let cal = Calendar.current
        let end = cal.startOfDay(for: .now)
        guard let start = cal.date(byAdding: .day, value: -days, to: end),
              // tot en met vandaag → bovengrens een dag verder, anders valt vandaag erbuiten
              let tomorrow = cal.date(byAdding: .day, value: 1, to: end) else { return }

        stepsByDay = await daily(stepType, options: .cumulativeSum, unit: .count(),
                                 start: start, end: tomorrow).mapValues { Int($0) }
        restingHRByDay = await daily(restingHRType, options: .discreteAverage, unit: bpm,
                                     start: start, end: tomorrow).mapValues { Int($0.rounded()) }
        hrvByDay = await daily(hrvType, options: .discreteAverage, unit: .secondUnit(with: .milli),
                               start: start, end: tomorrow).mapValues { Int($0.rounded()) }
        sleepByDay = await nights(start: start, end: tomorrow)
    }

    /// Dagwaarden van één meting. Som voor wat je optelt (stappen), gemiddelde voor wat
    /// een momentopname is (hartslag) — anders is "70 + 68 + 71" je rust-hartslag.
    private func daily(_ type: HKQuantityType, options: HKStatisticsOptions, unit: HKUnit,
                       start: Date, end: Date) async -> [Date: Double] {
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(
                type: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1))

        guard let result = try? await query.result(for: store) else { return [:] }
        let cal = Calendar.current
        var out: [Date: Double] = [:]
        result.enumerateStatistics(from: start, to: end) { stats, _ in
            let quantity = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
            if let value = quantity?.doubleValue(for: unit), value > 0 {
                out[cal.startOfDay(for: stats.startDate)] = value
            }
        }
        return out
    }

    /// Slaap komt als losse blokken binnen (licht, diep, REM, wakker tussendoor). Eén
    /// nacht is hier: het vroegste begin en het laatste eind van de blokken die vóór het
    /// middaguur eindigen, geboekt op de ochtend waarop je wakker werd.
    ///
    /// shortcut: een middagdutje telt dus niet mee, upgraden zodra je dutjes wil zien.
    private func nights(start: Date, end: Date) async -> [Date: Night] {
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: sleepType,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])

        guard let samples = try? await query.result(for: store) else { return [:] }
        return Self.nights(fromAsleepBlocks: samples
            .filter { asleep.contains($0.value) }
            .map { (start: $0.startDate, end: $0.endDate) })
    }

    /// De blokken samenvoegen tot nachten. Apart en puur, zodat het te testen is zonder
    /// een Health-store vol echte slaap.
    static func nights(fromAsleepBlocks blocks: [(start: Date, end: Date)]) -> [Date: Night] {
        let cal = Calendar.current
        var out: [Date: Night] = [:]
        for block in blocks {
            guard cal.component(.hour, from: block.end) < 12 else { continue }
            let morning = cal.startOfDay(for: block.end)
            out[morning] = Night(bed: min(out[morning]?.bed ?? block.start, block.start),
                                 wake: max(out[morning]?.wake ?? block.end, block.end))
        }
        return out
    }

    /// Gemiddelde en hoogste hartslag in een tijdvenster — de duur van je training.
    ///
    /// Niet opgeslagen: Health heeft het al, en een eigen kolom zou ook nog moeten
    /// syncen. Dit draait als je de dag opent, niet als je traint.
    func heartRate(from: Date, to: Date) async -> (avg: Int, max: Int)? {
        guard isAvailable, authorized, to > from else { return nil }
        let query = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(
                type: heartRateType,
                predicate: HKQuery.predicateForSamples(withStart: from, end: to)),
            options: [.discreteAverage, .discreteMax])

        guard let stats = try? await query.result(for: store),
              let avg = stats.averageQuantity()?.doubleValue(for: bpm),
              let peak = stats.maximumQuantity()?.doubleValue(for: bpm) else { return nil }
        return (Int(avg.rounded()), Int(peak.rounded()))
    }
}
