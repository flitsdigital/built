import Foundation
import SwiftData
import Supabase
import Observation
import AuthenticationServices
import UIKit

/// ISO8601 mét fracties — precies wat PostgREST zelf ook stuurt.
///
/// `ISO8601DateFormatter` is thread-safe voor formatteren maar niet als `Sendable`
/// gemarkeerd, en de encoder draait op een achtergrond-task. Eén gedeelde instantie achter
/// `@unchecked Sendable` is goedkoper dan een formatter per datum: dat zijn er duizenden
/// per push.
private final class ISODate: @unchecked Sendable {
    static let shared = ISODate()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    func string(from date: Date) -> String { formatter.string(from: date) }
}

/// Presentatie-anker voor de Google OAuth-websessie.
@MainActor
final class OAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresenter()
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

/// Zichtbare sync-status voor Profiel en dashboard.
@Observable
final class SyncStatus {
    static let shared = SyncStatus()
    var lastError: String?
    var lastSyncAt: Date?

    /// Sinds wanneer er lokale wijzigingen zijn die nergens anders staan. nil = de server
    /// heeft alles. Overleeft een herstart: een toestel dat dagen niet pusht moet dat
    /// blijven melden, ook als je de app tussendoor sluit.
    var pendingSince: Date? {
        didSet {
            UserDefaults.standard.set(pendingSince?.timeIntervalSinceReferenceDate ?? 0,
                                      forKey: Self.pendingKey)
        }
    }

    private static let pendingKey = "syncPendingSince"

    init() {
        let stamp = UserDefaults.standard.double(forKey: Self.pendingKey)
        pendingSince = stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
    }

    /// Laatste geslaagde sync, ook van vóór deze app-start: `lastSyncAt` begint bij
    /// elke start op nil, de timestamp in UserDefaults overleeft dat.
    var lastSuccess: Date? {
        if let lastSyncAt { return lastSyncAt }
        let stamp = UserDefaults.standard.double(forKey: "lastSync")
        return stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
    }

    /// Langer dan een dag werk dat alleen op dit toestel bestaat. Bewust gemeten aan de
    /// oudste openstaande wijziging en niet aan "laatst gesynct": een week zonder iets
    /// invoeren is geen probleem, een week met invoer die nergens aankomt wel.
    ///
    /// Een mislukte push zet geen foutmelding als het toestel simpelweg offline is, dus
    /// dit is vaak het enige signaal dat er iets klemt.
    var isStale: Bool {
        guard let pendingSince else { return false }
        return Date.now.timeIntervalSince(pendingSince) > 24 * 60 * 60
    }
}

// Supabase bewaart wat het toestel heeft: de app pusht wijzigingen automatisch en een
// lege install haalt alles op.
//
// Het protocol is delta én uitsluitend samenvoegend. `sync_push_v2` upsert alleen de
// rijen die meegestuurd worden — een rij die de payload niet noemt blijft staan — en de
// conflictregel (`t.updated_at <= excluded.updated_at`) zorgt dat een oudere versie een
// nieuwere nooit overschrijft. `sync_pull(since)` geeft alleen terug wat sindsdien
// gewijzigd is, en wordt lokaal op `syncID` samengevoegd. Beide gaan via één RPC, dus een
// push blijft één transactie — netwerkuitval laat nooit een halve staat achter.
//
// Wat hier bewust níet meer bestaat (#42): een modus waarin één kant "de waarheid" is.
// Divergentie tussen toestel en server wordt opgelost door samen te voegen, nooit door te
// wissen. Weet de app niet wélke rijen gewijzigd zijn (koude start met openstaande
// wijzigingen), dan gaat álles mee als één grote delta — dat is duur, niet gevaarlijk.
@MainActor
enum Sync {
    // MARK: - Rijen (kolomnamen = snake_case zoals in Postgres)
    //
    // Geen `user_id`: sync_push haalt de uid uit de sessie en negeert wat de client
    // meestuurt. Het veld was 49 bytes per rij aan dood gewicht.
    //
    // `id` is de `syncID` van het model: het toestel bepaalt de primary key, want anders
    // kan de client geen enkele rij aanwijzen.
    //
    // `updated_at`/`deleted_at` zijn strings, geen Dates. PostgREST levert microseconden
    // ("…:12.123456+00:00") en die haalt `ISO8601DateFormatter` er niet betrouwbaar uit;
    // als string gaan ze ongewijzigd heen en weer en parseert Postgres ze zelf. Bij een
    // push is `updated_at` nil op het volledige pad — dan zet de server z'n eigen now(),
    // wat meteen de vingerafdruk stabiel houdt.
    //
    // Sendable: de payload gaat naar een achtergrond-task om te encoden en te hashen.

    private struct ProfileRow: Codable, Sendable {
        var name: String; var age: Int; var height_cm: Int
        var start_weight: Double; var goal_weight: Double
        var start_date: Date; var goal_date: Date; var trainings_per_week: Int
        var tracks_creatine: Bool
        var tracks_sleep: Bool
        var training_days: [Int]
        var kcal_target: Int
        var schedule: [String: String]
        var tracks_food: Bool? = true
        var food_counts_for_score: Bool? = true
    }
    private struct WeightRow: Codable, Sendable, SyncRow {
        var id: UUID; var date: Date; var kg: Double; var scale: String
        var updated_at: String?; var deleted_at: String?
    }
    private struct ProteinRow: Codable, Sendable, SyncRow {
        var id: UUID; var date: Date; var grams: Int; var label: String
        var kcal: Int; var carbs: Int; var fat: Int; var meal: String
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var amount: Double? = 0
        var unit: String? = "g"
        var updated_at: String?; var deleted_at: String?
    }
    private struct FoodRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var brand: String; var barcode: String
        var protein100: Double; var kcal100: Double; var carbs100: Double; var fat100: Double
        var favorite: Bool; var image_url: String
        var serving_grams: Double; var serving_name: String; var created_at: Date
        var unit: String? = "g"
        var last_amount: Double? = 0
        var categories: String? = ""
        var updated_at: String?; var deleted_at: String?
    }
    private struct SetRow: Codable, Sendable, SyncRow {
        var id: UUID; var date: Date; var exercise: String; var weight_kg: Double; var reps: Int
        var dropset: Bool? = false; var failure: Bool? = false
        var seconds: Int? = 0
        var workout_id: UUID? = nil
        var updated_at: String?; var deleted_at: String?
    }
    private struct HabitsRow: Codable, Sendable, SyncRow {
        var id: UUID; var date: Date; var creatine: Bool; var slept_enough: Bool
        var note: String; var bed_time: Date?; var wake_time: Date?; var sleep_quality: Int
        var journal: [JournalNote]? = []
        var workout_note: String? = ""
        var energy: Int? = 0
        var mood: Int? = 0
        var soreness: Int? = 0
        var stress: Int? = 0
        var exercise_notes: [String: String]? = [:]
        var workout_name: String? = ""
        var workout_names: [String: String]? = [:]
        var workout_notes: [String: String]? = [:]
        var updated_at: String?; var deleted_at: String?
    }
    private struct RoutineRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var exercises: [String]
        var alternatives: [String: [String]]; var targets: [String: [Int]]
        var supersets: [String: String]; var rest_by_exercise: [String: Int]; var created_at: Date
        var updated_at: String?; var deleted_at: String?
    }
    private struct MealRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var protein: Int; var kcal: Int
        var created_at: Date; var servings: Double; var ingredients: [Ingredient]
        var favorite: Bool
        var updated_at: String?; var deleted_at: String?
    }
    // `scales.correction` bestaat wel in Postgres maar niet in het model; sync_push
    // laat 'm daarom op z'n default staan i.p.v. altijd 0 mee te sturen.
    private struct ScaleRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String
        var updated_at: String?; var deleted_at: String?
    }
    private struct CustomHabitRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var created_at: Date
        var updated_at: String?; var deleted_at: String?
    }
    private struct ExerciseRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var muscle: String; var type: String; var created_at: Date
        var archived: Bool?
        var secondary_muscles: [String]? = []
        var updated_at: String?; var deleted_at: String?
    }
    private struct HabitLogRow: Codable, Sendable, SyncRow {
        var id: UUID; var name: String; var date: Date
        var updated_at: String?; var deleted_at: String?
    }

    /// Een verwijderde rij: de rij zelf is weg, dus alleen tabel en id gaan mee.
    struct DeletionRow: Codable, Sendable {
        var table: String
        var id: UUID
        var deleted_at: String
    }

    private struct Payload: Codable, Sendable {
        var profile: ProfileRow?
        var weights: [WeightRow] = []
        var proteins: [ProteinRow] = []
        var sets: [SetRow] = []
        var habits: [HabitsRow] = []
        var routines: [RoutineRow] = []
        var meals: [MealRow] = []
        var foods: [FoodRow] = []
        var exercises: [ExerciseRow] = []
        var scales: [ScaleRow] = []
        var customHabits: [CustomHabitRow] = []
        var habitLogs: [HabitLogRow] = []
        var deletions: [DeletionRow] = []

        var isEmpty: Bool {
            profile == nil && weights.isEmpty && proteins.isEmpty && sets.isEmpty && habits.isEmpty
                && routines.isEmpty && meals.isEmpty && foods.isEmpty && exercises.isEmpty
                && scales.isEmpty && customHabits.isEmpty && habitLogs.isEmpty && deletions.isEmpty
        }
    }

    private struct PushParams: Encodable, Sendable {
        let payload: Payload
    }

    /// Antwoord van `sync_pull`. `server_time` blijft een string — die gaat ongewijzigd
    /// terug als `since` bij de volgende pull, dus er valt niets te parsen.
    private struct PullResponse: Decodable {
        var server_time: String
        var profile: ProfileRow?
        var weights: [WeightRow] = []
        var proteins: [ProteinRow] = []
        var sets: [SetRow] = []
        var habits: [HabitsRow] = []
        var routines: [RoutineRow] = []
        var meals: [MealRow] = []
        var foods: [FoodRow] = []
        var exercises: [ExerciseRow] = []
        var scales: [ScaleRow] = []
        var customHabits: [CustomHabitRow] = []
        var habitLogs: [HabitLogRow] = []

        /// Niets gewijzigd sinds het anker — het normale antwoord op een dagelijkse start.
        var isEmpty: Bool {
            profile == nil && weights.isEmpty && proteins.isEmpty && sets.isEmpty && habits.isEmpty
                && routines.isEmpty && meals.isEmpty && foods.isEmpty && exercises.isEmpty
                && scales.isEmpty && customHabits.isEmpty && habitLogs.isEmpty
        }
    }

    private struct PullParams: Encodable, Sendable { let since: String? }

    // MARK: - Client

    /// URL en anon key apart bewaard: de gzip-push bouwt een eigen URLRequest en heeft
    /// ze allebei nodig.
    private struct Config: Sendable { let url: URL; let key: String }

    private static let config: Config? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String],
              let urlString = dict["SUPABASE_URL"], let key = dict["SUPABASE_ANON_KEY"],
              !urlString.isEmpty, !key.isEmpty, let supabaseURL = URL(string: urlString)
        else { return nil }
        return Config(url: supabaseURL, key: key)
    }()

    // emitLocalSessionAsInitialSession: supabase-swift waarschuwt dat het huidige
    // gedrag (eerst refreshen, dán de sessie uitzenden) een bug is die in de
    // volgende major omklapt. Nu al opt-in, dan verandert er straks niets.
    static let client: SupabaseClient? = config.map {
        SupabaseClient(supabaseURL: $0.url, supabaseKey: $0.key,
                       options: .init(auth: .init(emitLocalSessionAsInitialSession: true)))
    }

    static var isConfigured: Bool { client != nil }

    /// POST naar een edge function, met de sessie erin. nil als Supabase niet
    /// geconfigureerd is of er (nog) geen sessie is — de beller moet dan zelf iets anders
    /// verzinnen, niet wachten.
    static func functionRequest(_ name: String, body: Data) -> URLRequest? {
        guard let config, let token = client?.auth.currentSession?.accessToken else { return nil }
        var request = URLRequest(url: config.url.appending(path: "functions/v1/\(name)"))
        request.httpMethod = "POST"
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = body
        return request
    }

    /// Geen sessie = geen account, en dat is een echte fout: nooit stilletjes een nieuw
    /// account maken. Dat wiste voorheen bij een mislukte token-refresh de koppeling met
    /// de echte gebruiker en schreef de hele dataset onder een vers user_id weg.
    private static func userID() async throws -> UUID {
        guard let client else { throw notConfigured() }
        return try await client.auth.session.user.id
    }

    // MARK: - Rijen uit modellen

    private static func row(_ e: WeightEntry, _ at: String?) -> WeightRow {
        WeightRow(id: e.syncID, date: e.date, kg: e.kg, scale: e.scale, updated_at: at)
    }
    private static func row(_ e: ProteinEntry, _ at: String?) -> ProteinRow {
        ProteinRow(id: e.syncID, date: e.date, grams: e.grams, label: e.label, kcal: e.kcal,
                   carbs: e.carbs, fat: e.fat, meal: e.meal, amount: e.amount, unit: e.unit,
                   updated_at: at)
    }
    private static func row(_ e: SetEntry, _ at: String?) -> SetRow {
        SetRow(id: e.syncID, date: e.date, exercise: e.exercise, weight_kg: e.weightKg, reps: e.reps,
               dropset: e.dropset, failure: e.failure, seconds: e.seconds,
               workout_id: e.workoutID == .zero ? nil : e.workoutID, updated_at: at)
    }
    private static func row(_ e: DayHabits, _ at: String?) -> HabitsRow {
        HabitsRow(id: e.syncID, date: e.date, creatine: e.creatine, slept_enough: e.sleptEnough,
                  note: e.note, bed_time: e.bedTime, wake_time: e.wakeTime, sleep_quality: e.sleepQuality,
                  journal: e.journal, workout_note: e.workoutNote, energy: e.energy, mood: e.mood,
                  soreness: e.soreness, stress: e.stress, exercise_notes: e.exerciseNotes,
                  workout_name: e.workoutName, workout_names: e.workoutNames,
                  workout_notes: e.workoutNotes, updated_at: at)
    }
    private static func row(_ e: Routine, _ at: String?) -> RoutineRow {
        RoutineRow(id: e.syncID, name: e.name, exercises: e.exercises, alternatives: e.alternatives,
                   targets: e.targets, supersets: e.supersets, rest_by_exercise: e.restByExercise,
                   created_at: e.createdAt, updated_at: at)
    }
    private static func row(_ e: Meal, _ at: String?) -> MealRow {
        MealRow(id: e.syncID, name: e.name, protein: e.protein, kcal: e.kcal, created_at: e.createdAt,
                servings: e.servings, ingredients: e.ingredients, favorite: e.favorite, updated_at: at)
    }
    private static func row(_ e: FoodProduct, _ at: String?) -> FoodRow {
        FoodRow(id: e.syncID, name: e.name, brand: e.brand, barcode: e.barcode,
                protein100: e.protein100, kcal100: e.kcal100, carbs100: e.carbs100, fat100: e.fat100,
                favorite: e.favorite, image_url: e.imageURL, serving_grams: e.servingGrams,
                serving_name: e.servingName, created_at: e.createdAt, unit: e.unit,
                last_amount: e.lastAmount, categories: e.categories, updated_at: at)
    }
    private static func row(_ e: Exercise, _ at: String?) -> ExerciseRow {
        ExerciseRow(id: e.syncID, name: e.name, muscle: e.muscle, type: e.type,
                    created_at: e.createdAt, archived: e.archived,
                    secondary_muscles: e.secondaryMuscles, updated_at: at)
    }
    private static func row(_ e: Scale, _ at: String?) -> ScaleRow {
        ScaleRow(id: e.syncID, name: e.name, updated_at: at)
    }
    private static func row(_ e: CustomHabit, _ at: String?) -> CustomHabitRow {
        CustomHabitRow(id: e.syncID, name: e.name, created_at: e.createdAt, updated_at: at)
    }
    private static func row(_ e: HabitLog, _ at: String?) -> HabitLogRow {
        HabitLogRow(id: e.syncID, name: e.name, date: e.date, updated_at: at)
    }
    private static func row(_ p: Profile) -> ProfileRow {
        ProfileRow(name: p.name, age: p.age, height_cm: p.heightCm, start_weight: p.startWeight,
                   goal_weight: p.goalWeight, start_date: p.startDate, goal_date: p.goalDate,
                   trainings_per_week: p.trainingsPerWeek, tracks_creatine: p.tracksCreatine,
                   tracks_sleep: p.tracksSleep, training_days: p.trainingDays,
                   kcal_target: p.kcalTarget, schedule: p.schedule, tracks_food: p.tracksFood,
                   food_counts_for_score: p.foodCountsForScore)
    }

    // MARK: - Verzamelen

    /// Alles, gesorteerd zodat de vingerafdruk stabiel is. `updated_at` blijft leeg: de
    /// server zet dan z'n eigen now(), en de vingerafdruk verandert niet bij elke collect.
    private static func collect(_ context: ModelContext) throws -> Payload {
        var p = Payload()
        if let profile = try context.fetch(FetchDescriptor<Profile>()).first { p.profile = row(profile) }
        p.weights = try context.fetch(FetchDescriptor<WeightEntry>(sortBy: [.init(\.date)])).map { row($0, nil) }
        p.proteins = try context.fetch(FetchDescriptor<ProteinEntry>(sortBy: [.init(\.date)])).map { row($0, nil) }
        p.sets = try context.fetch(FetchDescriptor<SetEntry>(sortBy: [.init(\.date)])).map { row($0, nil) }
        p.habits = try context.fetch(FetchDescriptor<DayHabits>(sortBy: [.init(\.date)])).map { row($0, nil) }
        p.routines = try context.fetch(FetchDescriptor<Routine>(sortBy: [.init(\.createdAt)])).map { row($0, nil) }
        p.meals = try context.fetch(FetchDescriptor<Meal>(sortBy: [.init(\.createdAt)])).map { row($0, nil) }
        p.foods = try context.fetch(FetchDescriptor<FoodProduct>(sortBy: [.init(\.createdAt)])).map { row($0, nil) }
        p.exercises = try context.fetch(FetchDescriptor<Exercise>(sortBy: [.init(\.name)])).map { row($0, nil) }
        p.scales = try context.fetch(FetchDescriptor<Scale>(sortBy: [.init(\.name)])).map { row($0, nil) }
        p.customHabits = try context.fetch(FetchDescriptor<CustomHabit>(sortBy: [.init(\.createdAt)])).map { row($0, nil) }
        p.habitLogs = try context.fetch(FetchDescriptor<HabitLog>(sortBy: [.init(\.date)])).map { row($0, nil) }
        p.deletions = deletions
        return p
    }

    /// Alleen wat sinds de laatste geslaagde push gewijzigd is.
    ///
    /// SwiftData meldt bij elke save wélke rijen zijn ingevoegd of gewijzigd, dus hoeft
    /// hier geen enkele tabel gescand te worden: `model(for:)` is een directe opzoeking.
    /// Een afgevinkte set levert zo een payload van één rij op in plaats van 6.980.
    private static func collectDelta(_ context: ModelContext) -> Payload {
        var p = Payload()
        for (identifier, stamp) in changes {
            let at = ISODate.shared.string(from: stamp)
            let model = context.model(for: identifier)
            guard !model.isDeleted else { continue }
            switch model {
            case let m as Profile: p.profile = row(m)
            case let m as WeightEntry: p.weights.append(row(m, at))
            case let m as ProteinEntry: p.proteins.append(row(m, at))
            case let m as SetEntry: p.sets.append(row(m, at))
            case let m as DayHabits: p.habits.append(row(m, at))
            case let m as Routine: p.routines.append(row(m, at))
            case let m as Meal: p.meals.append(row(m, at))
            case let m as FoodProduct: p.foods.append(row(m, at))
            case let m as Exercise: p.exercises.append(row(m, at))
            case let m as Scale: p.scales.append(row(m, at))
            case let m as CustomHabit: p.customHabits.append(row(m, at))
            case let m as HabitLog: p.habitLogs.append(row(m, at))
            default: break // PhotoEntry en al het niet-gesynchroniseerde
            }
        }
        p.deletions = deletions
        return p
    }

    // MARK: - Push

    /// Alles mee. De aanroeper komt hier alleen als er iets te pushen valt: `pushIfChanged`
    /// slaat een schone staat over zonder ook maar te verzamelen. Hier stond een SHA-256
    /// over de volledige database om een gelijke staat te herkennen — maar die moest
    /// daarvoor toch al alles verzamelen en encoden, dus het spaarde alleen de upload uit
    /// van iets wat hooguit wekelijks gebeurt.
    private static func pushFull(_ context: ModelContext) async throws {
        _ = try await userID() // geldige sessie; zonder account komt niemand hier
        // Vóór het verzamelen, want alles wat ná dit moment binnenkomt zit niet in de
        // payload en moet blijven staan. `collect` zelf heeft geen await, dus daar kan
        // geen save tussendoor glippen.
        let cutoff = Date.now
        let p = try collect(context)
        guard client != nil else { return }
        do {
            try await send(p)
        } catch {
            SyncStatus.shared.lastError = "Sync mislukt: \(message(for: error))"
            throw error
        }
        lastFullPush = .now
        finishPush(upTo: cutoff, deletions: p.deletions)
    }

    /// Alleen de gewijzigde rijen. Rijen die de payload niet noemt blijven op de server
    /// staan zoals ze zijn. Geeft false als er niets aan te wijzen viel.
    @discardableResult
    private static func pushDelta(_ context: ModelContext) async throws -> Bool {
        _ = try await userID()
        let cutoff = Date.now
        let p = collectDelta(context)
        guard client != nil else { return false }
        guard !p.isEmpty else { return false }
        do {
            try await send(p)
        } catch {
            SyncStatus.shared.lastError = "Sync mislukt: \(message(for: error))"
            throw error
        }
        finishPush(upTo: cutoff, deletions: p.deletions)
        return true
    }

    /// Streept weg wat aantoonbaar op de server staat, en laat de rest staan.
    ///
    /// Een `removeAll()` hier wiste ook de rijen die tijdens de push binnenkwamen: die
    /// zaten niet in de payload, en de client was daarna vergeten dat ze bestonden. Pas
    /// bij de eerstvolgende volledige push (hooguit wekelijks) kwamen ze alsnog mee.
    private static func clearSynced(upTo cutoff: Date, deletions sent: [DeletionRow]) {
        changes = changes.filter { $0.value > cutoff }
        let sentIDs = Set(sent.map(\.id))
        deletions.removeAll { sentIDs.contains($0.id) }
        isClean = changes.isEmpty && deletions.isEmpty
        dirty = !isClean
        deltaValid = true
        // Alles weg = niets staat nog alleen hier. Bleef er iets liggen (binnengekomen
        // tijdens de push), dan begint de klok voor dát werk nu pas.
        SyncStatus.shared.pendingSince = isClean ? nil : .now
    }

    private static func finishPush(upTo cutoff: Date, deletions sent: [DeletionRow]) {
        clearSynced(upTo: cutoff, deletions: sent)
        pushFailures = 0
        retryPushAfter = nil
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")
    }

    // MARK: - Transport

    private static func send(_ payload: Payload) async throws {
        guard let db = client else { return }
        _ = try await db.rpc("sync_push_v2", params: PushParams(payload: payload)).execute()
    }

    // MARK: - Pull

    /// Haalt de serverstaat op en voegt 'm samen met wat hier staat. `incremental` beperkt
    /// dat tot wat sinds de vorige pull gewijzigd is; zonder anker komt alles mee.
    ///
    /// Beide paden mergen op `syncID` — er wordt nooit iets lokaals gewist omdat de server
    /// het niet kent. Dat was de destructieve variant achter "Data ophalen van server", en
    /// precies die wiste vijf dagen werk (#42).
    static func pull(_ context: ModelContext, incremental: Bool = false) async throws {
        _ = try await userID()
        guard let db = client else { return }

        let since = incremental ? pullAnchor : nil
        let response: PullResponse = try await db.rpc("sync_pull", params: PullParams(since: since))
            .execute().value

        try applyMerge(response, context)
        pullAnchor = response.server_time
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")

        // Bracht de pull niets, dan heeft `applyMerge` ook niets geschreven en klopt de
        // delta-boekhouding nog precies. Dit is het normale antwoord bij elke app-start.
        guard !response.isEmpty else { return }

        // Wél iets binnengekregen: dan kan dit toestel rijen hebben die de server níet
        // kent (en andersom). Eén volledige push erachteraan laat beide kanten
        // convergeren — duur, maar het is de enige manier waarop niemand iets kwijtraakt.
        //
        // De losse identifiers zijn daarvoor niets waard: de rijen die `applyMerge` zelf
        // wegschrijft komen via dezelfde observer binnen, en een tijdstempel kan die niet
        // onderscheiden van een set die je tijdens het ophalen afvinkte (#31).
        changes.removeAll()
        deltaValid = false
        markDirty()
    }

    /// Samenvoegen op `syncID`: bestaande rij bijwerken, onbekende toevoegen, tombstone
    /// lokaal verwijderen. Lokale data die de server nog niet kent blijft staan.
    private static func applyMerge(_ r: PullResponse, _ context: ModelContext) throws {
        try context.transaction {
            if let p = r.profile {
                if let local = try context.fetch(FetchDescriptor<Profile>()).first {
                    apply(p, to: local)
                } else {
                    // Verse install: er is nog geen profiel om in te gieten.
                    let new = Profile(name: p.name, age: p.age, heightCm: p.height_cm,
                                      startWeight: p.start_weight, goalWeight: p.goal_weight,
                                      goalDate: p.goal_date, trainingsPerWeek: p.trainings_per_week)
                    apply(p, to: new)
                    context.insert(new)
                }
            }
            try merge(r.weights, WeightEntry.self, context) { apply($0, to: $1) }
            try merge(r.proteins, ProteinEntry.self, context) { apply($0, to: $1) }
            try merge(r.sets, SetEntry.self, context) { apply($0, to: $1) }
            try merge(r.habits, DayHabits.self, context) { apply($0, to: $1) }
            try merge(r.routines, Routine.self, context) { apply($0, to: $1) }
            try merge(r.meals, Meal.self, context) { apply($0, to: $1) }
            try merge(r.foods, FoodProduct.self, context) { apply($0, to: $1) }
            try merge(r.exercises, Exercise.self, context) { apply($0, to: $1) }
            try merge(r.scales, Scale.self, context) { apply($0, to: $1) }
            try merge(r.customHabits, CustomHabit.self, context) { apply($0, to: $1) }
            try merge(r.habitLogs, HabitLog.self, context) { apply($0, to: $1) }
            // De server kan nog rijen van vóór het afgeleide id bevatten; die zouden hier
            // als tweede "Bench Press" naast de eigen rij landen.
            Exercise.dedupe(context)
        }
    }

    /// Eén tabel samenvoegen. De index wordt één keer opgebouwd; per rij zoeken zou een
    /// fetch per rij betekenen.
    private static func merge<Row: SyncRow, Model: SyncedRecord>(
        _ rows: [Row], _ type: Model.Type, _ context: ModelContext,
        _ update: (Row, Model) -> Void) throws {
        guard !rows.isEmpty else { return }
        var byID = Dictionary(try context.fetch(FetchDescriptor<Model>()).map { ($0.syncID, $0) },
                              uniquingKeysWith: { first, _ in first })
        for r in rows {
            if r.deleted_at != nil {
                if let existing = byID[r.id] {
                    context.delete(existing) // geen deleteSynced: dit is de server die het zegt
                    byID[r.id] = nil
                }
                continue
            }
            if let existing = byID[r.id] {
                update(r, existing)
            } else {
                let created = Model.blank()
                created.syncID = r.id
                update(r, created)
                context.insert(created)
                byID[r.id] = created
            }
        }
    }

    // MARK: - Rij → model

    private static func apply(_ r: ProfileRow, to p: Profile) {
        p.name = r.name
        p.age = r.age
        p.heightCm = r.height_cm
        p.startWeight = r.start_weight
        p.goalWeight = r.goal_weight
        p.startDate = r.start_date
        p.goalDate = r.goal_date
        p.trainingsPerWeek = r.trainings_per_week
        p.tracksCreatine = r.tracks_creatine
        p.tracksSleep = r.tracks_sleep
        p.trainingDays = r.training_days
        p.kcalTarget = r.kcal_target
        p.schedule = r.schedule
        p.tracksFood = r.tracks_food ?? true
        p.foodCountsForScore = r.food_counts_for_score ?? true
    }

    private static func apply(_ r: WeightRow, to m: WeightEntry) {
        m.date = r.date; m.kg = r.kg; m.scale = r.scale
    }
    private static func apply(_ r: ProteinRow, to m: ProteinEntry) {
        m.date = r.date; m.grams = r.grams; m.label = r.label; m.kcal = r.kcal
        m.carbs = r.carbs; m.fat = r.fat; m.meal = r.meal
        m.amount = r.amount ?? 0; m.unit = r.unit ?? FoodUnit.gram.rawValue
    }
    private static func apply(_ r: SetRow, to m: SetEntry) {
        m.date = r.date; m.exercise = r.exercise; m.weightKg = r.weight_kg; m.reps = r.reps
        m.dropset = r.dropset ?? false; m.failure = r.failure ?? false; m.seconds = r.seconds ?? 0
        // Alleen overschrijven als de server iets zégt. Draait de migration nog niet, dan
        // bestaat de kolom daar niet, komt het veld als nil terug, en zou een `?? .zero`
        // het sessie-id bij elke pull lokaal wissen — en vallen twee trainingen van
        // dezelfde dag weer samen.
        if let w = r.workout_id { m.workoutID = w }
    }
    private static func apply(_ r: HabitsRow, to m: DayHabits) {
        m.date = r.date; m.creatine = r.creatine; m.sleptEnough = r.slept_enough
        m.note = r.note; m.bedTime = r.bed_time; m.wakeTime = r.wake_time
        m.sleepQuality = r.sleep_quality; m.journal = r.journal ?? []
        m.workoutNote = r.workout_note ?? ""
        m.energy = r.energy ?? 0; m.mood = r.mood ?? 0
        m.soreness = r.soreness ?? 0; m.stress = r.stress ?? 0
        m.exerciseNotes = r.exercise_notes ?? [:]
        m.workoutName = r.workout_name ?? ""
        // Zie `apply(_ r: SetRow…)`: nil is "kolom bestaat daar niet", niet "leeg".
        if let names = r.workout_names { m.workoutNames = names }
        if let notes = r.workout_notes { m.workoutNotes = notes }
    }
    private static func apply(_ r: RoutineRow, to m: Routine) {
        m.name = r.name; m.exercises = r.exercises; m.alternatives = r.alternatives
        m.targets = r.targets; m.supersets = r.supersets; m.restByExercise = r.rest_by_exercise
        m.createdAt = r.created_at
    }
    private static func apply(_ r: MealRow, to m: Meal) {
        m.name = r.name; m.protein = r.protein; m.kcal = r.kcal; m.createdAt = r.created_at
        m.servings = r.servings; m.ingredients = r.ingredients; m.favorite = r.favorite
    }
    private static func apply(_ r: FoodRow, to m: FoodProduct) {
        m.name = r.name; m.brand = r.brand; m.barcode = r.barcode
        m.protein100 = r.protein100; m.kcal100 = r.kcal100
        m.carbs100 = r.carbs100; m.fat100 = r.fat100
        m.favorite = r.favorite; m.imageURL = r.image_url
        m.servingGrams = r.serving_grams; m.servingName = r.serving_name
        m.createdAt = r.created_at; m.unit = r.unit ?? FoodUnit.gram.rawValue
        m.lastAmount = r.last_amount ?? 0; m.categories = r.categories ?? ""
    }
    private static func apply(_ r: ExerciseRow, to m: Exercise) {
        m.name = r.name; m.muscle = r.muscle; m.type = r.type; m.createdAt = r.created_at
        m.secondaryMuscles = r.secondary_muscles ?? []
        // Zie `apply(_ r: SetRow…)`: nil is "die kolom bestaat daar niet", niet "leeg".
        if let a = r.archived { m.archived = a }
    }
    private static func apply(_ r: ScaleRow, to m: Scale) { m.name = r.name }
    private static func apply(_ r: CustomHabitRow, to m: CustomHabit) {
        m.name = r.name; m.createdAt = r.created_at
    }
    private static func apply(_ r: HabitLogRow, to m: HabitLog) {
        m.name = r.name; m.date = r.date
    }

    // MARK: - Export en wissen

    /// Volledige data als JSON — back-up/portabiliteit los van de server.
    static func exportJSON(_ context: ModelContext) -> String? {
        guard let p = try? collect(context) else { return nil }
        let encoder = makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Het toestel leegmaken. Nog maar één aanroeper: uitloggen. De sync gebruikt dit sinds
    /// #42 niet meer — een pull voegt samen en wist nooit.
    private static func wipeLocal(_ context: ModelContext) throws {
        try context.delete(model: Profile.self)
        try context.delete(model: WeightEntry.self)
        try context.delete(model: ProteinEntry.self)
        try context.delete(model: SetEntry.self)
        try context.delete(model: DayHabits.self)
        try context.delete(model: Routine.self)
        try context.delete(model: Meal.self)
        try context.delete(model: FoodProduct.self)
        try context.delete(model: Exercise.self)
        try context.delete(model: Scale.self)
        try context.delete(model: CustomHabit.self)
        try context.delete(model: HabitLog.self)
        // Eigen productfoto's hangen aan barcode-of-naam, niet aan een account. Blijven ze
        // staan, dan zet de volgende gebruiker z'n Kwark neer en kijkt naar de foto van de
        // vorige — precies de botsing waarvoor deze functie bestaat.
        try? FileManager.default.removeItem(at: ProductPhoto.directory)
    }

    /// Uitloggen maakt het toestel leeg: zonder account kan de app toch niet syncen, en
    /// een achtergebleven lokale kopie zou bij de volgende login met een ánder account
    /// gaan botsen. Je data blijft op je account staan; opnieuw inloggen haalt 'm terug.
    static func signOut(context: ModelContext) async {
        try? await client?.auth.signOut()
        resetSyncState()
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = nil
        SyncStatus.shared.pendingSince = nil // toestel is leeg; er klemt niets meer
        UserDefaults.standard.removeObject(forKey: "lastSync")
        try? wipeLocal(context)
    }

    /// Ander account = schone lei. Het pull-anker slaat op de vorige gebruiker; laten
    /// staan zou betekenen dat de app denkt dat er niets meer op te halen valt.
    private static func resetSyncState() {
        pullAnchor = nil
        deletions = []
        changes.removeAll()
        isClean = false
        deltaValid = false
        dirty = true
        pushFailures = 0
        retryPushAfter = nil
    }

    // MARK: - Bootstrap: haal op wat er nog niet is

    /// Bij de start ophalen wat elders is gebeurd, en samenvoegen.
    ///
    /// Hier stond een vergelijking van `start_date` die bij een verschil de push stilzette
    /// en naar "Data ophalen van server" verwees. Beide zijn weg (#42): een profielverschil
    /// betekent hooguit dat er ooit een tweede identiteit is geweest, en dat los je op door
    /// samen te voegen. De push stilzetten maakte het verschil alleen groter — vijf dagen
    /// lang, zonder dat iemand het zag.
    static func bootstrap(_ context: ModelContext) async {
        guard isConfigured, hasSession else { return } // uitgelogd = niets te syncen, geen foutmelding
        do {
            let uid = try await userID()
            let serverProfiles: [ProfileRow] = try await client!.from("profiles").select().eq("user_id", value: uid).execute().value
            guard !serverProfiles.isEmpty else { return } // lege server; de eerste push vult 'm
            let hasLocalProfile = try context.fetch(FetchDescriptor<Profile>()).first != nil
            // Geen lokaal profiel of nooit eerder gepulld → alles ophalen. Anders de delta.
            try await pull(context, incremental: hasLocalProfile && pullAnchor != nil)
        } catch {
            SyncStatus.shared.lastError = "Sync-check mislukt: \(message(for: error))"
        }
    }

    // MARK: - Account (e-mail + wachtwoord of Google)

    static var currentEmail: String? {
        client?.auth.currentSession?.user.email.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Actieve sessie? Na registreren met e-mailbevestiging-aan is die er nog niet.
    static var hasSession: Bool { client?.auth.currentSession != nil }

    /// Voor de gebruiker leesbare fout. "Auth session missing." is de meest voorkomende en
    /// de minst behulpzame: het zegt niet wat je eraan kunt doen, en zeker niet dat je
    /// lokale data gewoon nog bestaat.
    static func message(for error: Error) -> String {
        if let error = error as? AuthError, case .sessionMissing = error {
            return "Niet meer ingelogd op dit toestel. Je data staat er nog; log in via \"Ander account\" en alles gaat alsnog mee."
        }
        return error.localizedDescription
    }

    private static func notConfigured() -> Error {
        NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supabase niet geconfigureerd — vul Built/Secrets.plist in."])
    }

    /// Registreren. Levert `false` op als het account wel is aangemaakt maar er nog geen
    /// sessie is — dan staat e-mailbevestiging aan in Supabase en moet de gebruiker eerst
    /// de link in z'n mail aantikken.
    @discardableResult
    static func register(email: String, password: String, context: ModelContext) async throws -> Bool {
        guard let client else { throw notConfigured() }
        let result = try await client.auth.signUp(email: email, password: password)
        guard result.session != nil else { return false }
        resetSyncState()
        SyncStatus.shared.lastError = nil
        await bootstrap(context)
        return true
    }

    /// Stuurt een wachtwoord-reset-mail zodat een gebruiker niet buitengesloten raakt.
    static func resetPassword(email: String) async throws {
        guard let client else { throw notConfigured() }
        try await client.auth.resetPasswordForEmail(email)
    }

    /// Inloggen op een bestaand account; haalt daarna veilig de serverstaat op.
    static func signIn(email: String, password: String, context: ModelContext) async throws {
        guard let client else { throw notConfigured() }
        try await client.auth.signIn(email: email, password: password)
        resetSyncState()
        SyncStatus.shared.lastError = nil
        await bootstrap(context)
    }

    /// Google via Supabase OAuth (ASWebAuthenticationSession, geen extra SDK).
    static func signInWithGoogle(context: ModelContext) async throws {
        guard let client else { throw notConfigured() }
        let authURL = try client.auth.getOAuthSignInURL(provider: .google,
                                                        redirectTo: URL(string: "built://auth-callback")!)
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "built") { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? notConfigured())
                }
            }
            session.presentationContextProvider = OAuthPresenter.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        try await client.auth.session(from: callbackURL)
        resetSyncState()
        SyncStatus.shared.lastError = nil
        await bootstrap(context)
    }

    /// Verwijdert het account volledig: alle serverdata + de auth-user (via RPC met
    /// verhoogde rechten), daarna het toestel leegmaken. Onomkeerbaar.
    static func deleteAccount(context: ModelContext) async throws {
        guard let client else { throw notConfigured() }
        try await client.rpc("delete_account").execute()
        // Server-account is weg; signOut ruimt de lokale sessie op en wist het toestel,
        // waarna de app op de onboarding uitkomt.
        await signOut(context: context)
    }

    // MARK: - Wijzigingen bijhouden

    /// Welke rijen sinds de laatste geslaagde push gewijzigd zijn, met het moment waarop we
    /// het zagen. Bewust niet bewaard tussen app-starts: `PersistentIdentifier` is niet
    /// bedoeld om op te slaan. Bij een koude start met openstaande wijzigingen valt de app
    /// daarom terug op een volledige push.
    private static var changes: [PersistentIdentifier: Date] = [:]

    /// Verwijderingen wél bewaren: de rij is weg, dus die kunnen we later niet opnieuw
    /// afleiden. Zonder dit zou een verwijdering die vlak voor het afsluiten gebeurt op de
    /// server blijven staan en bij de volgende pull terugkomen.
    private static let deletionsKey = "syncDeletions"
    private static var deletions: [DeletionRow] {
        get {
            guard let data = UserDefaults.standard.data(forKey: deletionsKey),
                  let rows = try? JSONDecoder().decode([DeletionRow].self, from: data) else { return [] }
            return rows
        }
        set {
            guard !newValue.isEmpty else {
                UserDefaults.standard.removeObject(forKey: deletionsKey)
                return
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: deletionsKey)
        }
    }

    /// Alleen voor tests: het spoor is bewust privé, maar het is precies het stuk dat je
    /// wil kunnen nakijken.
    static var pendingDeletionsForTesting: [DeletionRow] { deletions }
    static func clearDeletionsForTesting() { deletions = [] }

    /// Aangeroepen door `ModelContext.deleteSynced`.
    static func recordDeletion(table: String, syncID: UUID) {
        deletions.append(DeletionRow(table: table, id: syncID,
                                     deleted_at: ISODate.shared.string(from: .now)))
        isClean = false
        markDirty()
    }

    /// Staat alles wat lokaal is ook op de server? Overleeft een herstart, zodat het
    /// openen en sluiten van de app zonder wijzigingen nul pushes oplevert.
    private static let cleanKey = "syncClean"
    private static var isClean: Bool {
        get { UserDefaults.standard.bool(forKey: cleanKey) }
        set { UserDefaults.standard.set(newValue, forKey: cleanKey) }
    }

    /// Weten we precies wélke rijen gewijzigd zijn? Bij de start alleen als de vorige
    /// sessie schoon eindigde. Anders is er tussen twee starts iets gewijzigd waarvan we de
    /// rijen niet meer kunnen aanwijzen, en gaat er eerst één volledige push overheen.
    private static var deltaValid = UserDefaults.standard.bool(forKey: cleanKey)

    /// Ook als de delta-boekhouding klopt: eens per week een volledige push, zodat een
    /// eventueel verschil tussen toestel en server zich niet ongemerkt kan opstapelen.
    private static let fullPushKey = "lastFullPush"
    private static var lastFullPush: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: fullPushKey)
            return stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSinceReferenceDate, forKey: fullPushKey) }
            else { UserDefaults.standard.removeObject(forKey: fullPushKey) }
        }
    }

    private static var needsFullPush: Bool {
        guard deltaValid else { return true }
        guard let lastFullPush else { return true }
        return Date.now.timeIntervalSince(lastFullPush) > 7 * 24 * 60 * 60
    }

    /// Servertijd van de laatste pull, als string doorgegeven zoals PostgREST 'm levert.
    private static let anchorKey = "syncPullAnchor"
    private static var pullAnchor: String? {
        get { UserDefaults.standard.string(forKey: anchorKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: anchorKey) }
            else { UserDefaults.standard.removeObject(forKey: anchorKey) }
        }
    }

    // MARK: - Automatische sync-lus

    private static var running = false
    static var appActive = true

    /// Gaat aan bij elke lokale wijziging.
    private static var dirty = true

    /// Bij een mislukte push wachten we langer dan het vaste interval. Zonder deze rem
    /// blijft een langdurige storing (offline, server plat) elke ronde hameren.
    private static var pushFailures = 0
    private static var retryPushAfter: Date?

    /// Laat de sync-lus weten dat er iets te pushen valt.
    ///
    /// Zet ook `isClean` uit: de lus slaat een schone staat over zonder te kijken, en een
    /// aanroeper die dit aanroept weet iets wat de save-meldingen nog niet verteld hebben
    /// (de autosave kan nog moeten komen).
    static func markDirty() {
        dirty = true
        isClean = false
        // De klok begint bij de éérste openstaande wijziging, niet bij de laatste: het
        // dashboard moet melden hoe lang er al werk klemt, niet hoe recent je iets deed.
        if SyncStatus.shared.pendingSince == nil { SyncStatus.shared.pendingSince = .now }
    }

    /// Encoder voor de export.
    ///
    /// `sortedKeys` is geen cosmetica: `schedule`, `targets` en `exercise_notes` zijn
    /// dictionaries, en zonder vaste sleutelvolgorde levert dezelfde data twee keer een
    /// andere JSON op — en dus een andere vingerafdruk en een push zonder wijziging.
    /// ISO8601 met fracties is wat PostgREST zelf ook stuurt.
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(ISODate.shared.string(from: date))
        }
        return encoder
    }

    /// Interval van de achtergrond-lus.
    ///
    /// Stond op 20 seconden. Tijdens een training vink je continu sets af, dus stond
    /// `dirty` permanent aan en pushte hij ~180 keer per training de volledige historie.
    /// De sync is een back-up, geen live-opslag: SwiftData is al duurzaam en een
    /// force-quit midden in een training verliest niets (`draftSnapshot` vangt dat af).
    private static let interval: Duration = .seconds(300)

    private static var tracking = false

    /// Zo vroeg mogelijk aanzetten, vóór alles wat bij de start naar de store schrijft
    /// (`Exercise.bootstrap`, de id-backfill). Een save die hier langsloopt zonder dat de
    /// observer er is, zou ongemerkt buiten de delta vallen.
    ///
    /// SwiftData meldt bij elke save wat er is ingevoegd, gewijzigd en verwijderd. Dat is
    /// precies wat een delta-push nodig heeft: niet "er is iets veranderd", maar "déze rijen".
    static func startTracking() {
        guard !tracking else { return }
        tracking = true
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { record(note) }
        }
    }

    static func start(_ context: ModelContext) {
        guard isConfigured, !running else { return }
        running = true
        startTracking()
        Task {
            while true {
                try? await Task.sleep(for: interval)
                guard appActive else { continue } // ponytail: niet stampen in de achtergrond
                await pushIfChanged(context)
            }
        }
    }

    private static func record(_ note: Notification) {
        let stamp = Date.now
        let info = note.userInfo ?? [:]
        func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
            info[key.rawValue] as? [PersistentIdentifier] ?? []
        }
        // Een batch-delete (wipeLocal) meldt geen losse id's maar "alles ongeldig". De
        // bewaarde identifiers wijzen dan naar rijen die niet meer bestaan; die moeten weg
        // vóór iemand ze probeert op te zoeken.
        if info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil {
            changes.removeAll()
            deltaValid = false
            isClean = false
            markDirty()
            return
        }
        let touched = ids(.insertedIdentifiers) + ids(.updatedIdentifiers)
        let removed = ids(.deletedIdentifiers)
        // Niets herkenbaars in de melding terwijl er wél opgeslagen is: dan weten we niet
        // welke rijen het waren en is een delta niet te vertrouwen.
        if touched.isEmpty && removed.isEmpty { deltaValid = false }
        for id in touched { changes[id] = stamp }
        for id in removed { changes[id] = nil }
        isClean = false
        markDirty()
    }

    /// `force` markeert een bewust moment: einde training, of de app die naar de
    /// achtergrond gaat. Die mogen ook tijdens een training pushen. De lus niet — die zou
    /// anders elke ronde pushen zolang je aan het afvinken bent.
    static func pushIfChanged(_ context: ModelContext, force: Bool = false) async {
        // Geen `pushAllowed` meer: een push kan sinds #42 niets vernietigen, dus er is geen
        // situatie meer waarin het veiliger is om niet te pushen dan wel. Wél een sessie
        // nodig — anders levert de onboarding een foutmelding op over een sync die er nog
        // niet is.
        guard hasSession, dirty else { return }
        guard force || WorkoutStatus.shared.startedAt == nil else { return }
        if let retryPushAfter, Date.now < retryPushAfter { return }
        // Koude start zonder wijzigingen: de vorige sessie eindigde schoon, dus er valt
        // niets te doen. Dit is wat een lege push bij elke app-start voorkomt.
        if isClean, changes.isEmpty, deletions.isEmpty { dirty = false; return }
        do {
            if needsFullPush {
                try await pushFull(context)
            } else if try await pushDelta(context) == false {
                // Er is wél iets gewijzigd, maar we kunnen niet aanwijzen wát — de
                // save-melding kan nog onderweg zijn. Dan liever één volledige push (die
                // zichzelf overslaat als er toch niets veranderd is) dan een wijziging die
                // blijft liggen.
                try await pushFull(context)
            }
            // `dirty` wordt door clearSynced gezet: false als alles weg is, true als er
            // tijdens de push nog iets binnenkwam. Bij een fout blijft 'ie staan zodat de
            // lus het opnieuw probeert, ook als de gebruiker daarna niets meer wijzigt.
        } catch {
            pushFailures += 1
            retryPushAfter = .now.addingTimeInterval(min(20 * pow(2, Double(pushFailures)), 600))
            SyncStatus.shared.lastError = "Sync mislukt: \(message(for: error))"
        }
    }
}

// MARK: - Hulpprotocollen

/// Een rij zoals de server 'm teruggeeft: adresseerbaar, en herkenbaar als tombstone.
protocol SyncRow {
    var id: UUID { get }
    var deleted_at: String? { get }
}
