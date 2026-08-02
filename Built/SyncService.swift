import Foundation
import SwiftData
import Supabase
import Observation
import AuthenticationServices
import CryptoKit
import UIKit

/// ISO8601 mét fracties — precies wat PostgREST zelf ook stuurt, dus de datums komen
/// exact terug zoals ze weggeschreven zijn.
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

    /// Laatste geslaagde sync, ook van vóór deze app-start: `lastSyncAt` begint bij
    /// elke start op nil, de timestamp in UserDefaults overleeft dat.
    var lastSuccess: Date? {
        if let lastSyncAt { return lastSyncAt }
        let stamp = UserDefaults.standard.double(forKey: "lastSync")
        return stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
    }

    /// Langer dan een dag geleden gesynct. Een mislukte push zet geen foutmelding als
    /// het toestel simpelweg offline is, dus dit is vaak het enige signaal dat er iets
    /// klemt. Nooit gesynct telt niet mee — dat is gewoon een verse install.
    var isStale: Bool {
        guard let lastSuccess else { return false }
        return Date.now.timeIntervalSince(lastSuccess) > 24 * 60 * 60
    }
}

// Supabase is de source of truth: de app pusht wijzigingen automatisch en een lege
// install haalt alles op. Push gaat via één RPC (sync_push) die server-side in één
// transactie alles vervangt — geen half-gewiste tabellen bij netwerkuitval.
@MainActor
enum Sync {
    // MARK: - Rijen (kolomnamen = snake_case zoals in Postgres)
    //
    // Geen `user_id` in deze structs: sync_push haalt de uid uit de sessie en negeert
    // wat de client meestuurt (terecht — de client mag niet bepalen onder wiens id er
    // geschreven wordt). Het veld was daarmee 49 bytes per rij aan dood gewicht, ~24%
    // van de payload. Bij het decoderen van een pull wordt de kolom simpelweg genegeerd.
    //
    // Sendable: de payload gaat naar een achtergrond-task om te encoden en te hashen,
    // en dat is alleen veilig omdat het waardetypes tot op de bodem zijn.

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
    }
    private struct WeightRow: Codable, Sendable { var date: Date; var kg: Double; var scale: String }
    private struct ProteinRow: Codable, Sendable {
        var date: Date; var grams: Int; var label: String
        var kcal: Int; var carbs: Int; var fat: Int; var meal: String
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var amount: Double? = 0
        var unit: String? = "g"
    }
    private struct FoodRow: Codable, Sendable {
        var name: String; var brand: String; var barcode: String
        var protein100: Double; var kcal100: Double; var carbs100: Double; var fat100: Double
        var favorite: Bool; var image_url: String
        var serving_grams: Double; var serving_name: String; var created_at: Date
        var unit: String? = "g"
        var last_amount: Double? = 0
        var categories: String? = ""
    }
    private struct SetRow: Codable, Sendable {
        var date: Date; var exercise: String; var weight_kg: Double; var reps: Int
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var dropset: Bool? = false; var failure: Bool? = false
        var seconds: Int? = 0
    }
    private struct HabitsRow: Codable, Sendable {
        var date: Date; var creatine: Bool; var slept_enough: Bool
        var note: String; var bed_time: Date?; var wake_time: Date?; var sleep_quality: Int
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var journal: [JournalNote]? = []
        var workout_note: String? = ""
        var energy: Int? = 0
        var mood: Int? = 0
        var soreness: Int? = 0
        var stress: Int? = 0
        var exercise_notes: [String: String]? = [:]
    }
    private struct RoutineRow: Codable, Sendable {
        var name: String; var exercises: [String]
        var alternatives: [String: [String]]; var targets: [String: [Int]]
        var supersets: [String: String]; var rest_by_exercise: [String: Int]; var created_at: Date
    }
    private struct MealRow: Codable, Sendable {
        var name: String; var protein: Int; var kcal: Int
        var created_at: Date; var servings: Double; var ingredients: [Ingredient]
        var favorite: Bool
    }
    // `scales.correction` bestaat wel in Postgres maar niet in het model; sync_push
    // laat 'm daarom op z'n default staan i.p.v. altijd 0 mee te sturen.
    private struct ScaleRow: Codable, Sendable { var name: String }
    private struct CustomHabitRow: Codable, Sendable { var name: String; var created_at: Date }
    private struct ExerciseRow: Codable, Sendable { var name: String; var muscle: String; var type: String; var created_at: Date }
    private struct HabitLogRow: Codable, Sendable { var name: String; var date: Date }

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
    }

    private struct RPCParams: Encodable, Sendable { let payload: Payload }

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
    // De platform-init vult de standaard keychain-storage zelf in.
    static let client: SupabaseClient? = config.map {
        SupabaseClient(supabaseURL: $0.url, supabaseKey: $0.key,
                       options: .init(auth: .init(emitLocalSessionAsInitialSession: true)))
    }

    static var isConfigured: Bool { client != nil }

    /// Beslist of een mislukte `auth.session` mag uitmonden in een nieuw anoniem account.
    ///
    /// `auth.session` gooit in twee gevallen: er is geen opgeslagen sessie, óf de
    /// token-refresh mislukte (500 van de auth-server, timeout, een rotatie-race). Alleen
    /// het eerste geval rechtvaardigt een nieuw account. Werd bij het tweede geval tóch
    /// anoniem aangemeld, dan werd de gebruiker stil uitgelogd uit z'n echte account en
    /// werd z'n volledige dataset onder een vers `user_id` weggeschreven — onomkeerbaar,
    /// terwijl een mislukte sync zichzelf herstelt.
    ///
    /// De opgeslagen sessie is het onderscheid: supabase-swift wist die alleen als de
    /// refresh-token echt geweigerd is, niet bij een storing.
    static func mayCreateAnonymousAccount(hasStoredSession: Bool) -> Bool { !hasStoredSession }

    private static func userID() async throws -> UUID {
        guard let client else { throw notConfigured() }
        do {
            return try await client.auth.session.user.id
        } catch {
            guard mayCreateAnonymousAccount(hasStoredSession: client.auth.currentSession != nil) else { throw error }
            return try await client.auth.signInAnonymously().user.id
        }
    }

    // MARK: - Verzamelen (gesorteerd, zodat de change-hash stabiel is)

    private static func collect(_ context: ModelContext) throws -> Payload {
        var p = Payload()
        if let profile = try context.fetch(FetchDescriptor<Profile>()).first {
            p.profile = ProfileRow(name: profile.name, age: profile.age, height_cm: profile.heightCm,
                                   start_weight: profile.startWeight, goal_weight: profile.goalWeight,
                                   start_date: profile.startDate, goal_date: profile.goalDate,
                                   trainings_per_week: profile.trainingsPerWeek,
                                   tracks_creatine: profile.tracksCreatine, tracks_sleep: profile.tracksSleep,
                                   training_days: profile.trainingDays, kcal_target: profile.kcalTarget,
                                   schedule: profile.schedule, tracks_food: profile.tracksFood)
        }
        p.weights = try context.fetch(FetchDescriptor<WeightEntry>(sortBy: [.init(\.date)]))
            .map { WeightRow(date: $0.date, kg: $0.kg, scale: $0.scale) }
        p.proteins = try context.fetch(FetchDescriptor<ProteinEntry>(sortBy: [.init(\.date)]))
            .map { ProteinRow(date: $0.date, grams: $0.grams, label: $0.label,
                              kcal: $0.kcal, carbs: $0.carbs, fat: $0.fat, meal: $0.meal,
                              amount: $0.amount, unit: $0.unit) }
        p.sets = try context.fetch(FetchDescriptor<SetEntry>(sortBy: [.init(\.date)]))
            .map { SetRow(date: $0.date, exercise: $0.exercise, weight_kg: $0.weightKg, reps: $0.reps,
                          dropset: $0.dropset, failure: $0.failure, seconds: $0.seconds) }
        p.habits = try context.fetch(FetchDescriptor<DayHabits>(sortBy: [.init(\.date)]))
            .map { HabitsRow(date: $0.date, creatine: $0.creatine, slept_enough: $0.sleptEnough,
                             note: $0.note, bed_time: $0.bedTime, wake_time: $0.wakeTime, sleep_quality: $0.sleepQuality,
                             journal: $0.journal, workout_note: $0.workoutNote,
                             energy: $0.energy, mood: $0.mood, soreness: $0.soreness, stress: $0.stress,
                             exercise_notes: $0.exerciseNotes) }
        p.routines = try context.fetch(FetchDescriptor<Routine>(sortBy: [.init(\.createdAt)]))
            .map { RoutineRow(name: $0.name, exercises: $0.exercises,
                              alternatives: $0.alternatives, targets: $0.targets,
                              supersets: $0.supersets, rest_by_exercise: $0.restByExercise,
                              created_at: $0.createdAt) }
        p.meals = try context.fetch(FetchDescriptor<Meal>(sortBy: [.init(\.createdAt)]))
            .map { MealRow(name: $0.name, protein: $0.protein, kcal: $0.kcal,
                           created_at: $0.createdAt, servings: $0.servings, ingredients: $0.ingredients,
                           favorite: $0.favorite) }
        p.foods = try context.fetch(FetchDescriptor<FoodProduct>(sortBy: [.init(\.createdAt)]))
            .map { FoodRow(name: $0.name, brand: $0.brand, barcode: $0.barcode,
                           protein100: $0.protein100, kcal100: $0.kcal100,
                           carbs100: $0.carbs100, fat100: $0.fat100,
                           favorite: $0.favorite, image_url: $0.imageURL,
                           serving_grams: $0.servingGrams, serving_name: $0.servingName,
                           created_at: $0.createdAt,
                           unit: $0.unit, last_amount: $0.lastAmount, categories: $0.categories) }
        p.exercises = try context.fetch(FetchDescriptor<Exercise>(sortBy: [.init(\.name)]))
            .map { ExerciseRow(name: $0.name, muscle: $0.muscle, type: $0.type, created_at: $0.createdAt) }
        p.scales = try context.fetch(FetchDescriptor<Scale>(sortBy: [.init(\.name)]))
            .map { ScaleRow(name: $0.name) }
        p.customHabits = try context.fetch(FetchDescriptor<CustomHabit>(sortBy: [.init(\.createdAt)]))
            .map { CustomHabitRow(name: $0.name, created_at: $0.createdAt) }
        p.habitLogs = try context.fetch(FetchDescriptor<HabitLog>(sortBy: [.init(\.date)]))
            .map { HabitLogRow(name: $0.name, date: $0.date) }
        return p
    }

    // MARK: - Push (atomair via RPC)

    static func push(_ context: ModelContext) async throws {
        _ = try await userID() // geldige sessie, of anoniem aanmelden bij een verse install
        let p = try collect(context)
        guard client != nil else { return }
        do {
            try await send(p)
        } catch {
            SyncStatus.shared.lastError = "Sync mislukt: \(error.localizedDescription)"
            throw error
        }
        lastPushedHash = try await fingerprint(p)
        pushAllowed = true // expliciete push = bewuste overschrijving
        pushFailures = 0
        retryPushAfter = nil
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")
    }

    // MARK: - Transport
    //
    // De payload is bij uitstek comprimeerbaar: duizenden rijen met identieke sleutelnamen,
    // ISO-datums met een gedeelde prefix, herhaalde oefeningsnamen. Realistisch 8-12×
    // kleiner. supabase-swift zet zelf geen `Content-Encoding` en biedt geen haakje om een
    // voorgecodeerde body mee te geven, dus de gzip-variant gaat via een eigen URLRequest.
    //
    // Of de Supabase-gateway (Kong) `Content-Encoding: gzip` doorlaat naar PostgREST is per
    // project niet gegarandeerd. Daarom: proberen, en bij een afwijzing terugvallen op de
    // gewone RPC — en dat onthouden, zodat niet elke push twee keer gaat.

    /// De gateway wil de gzip-body niet. Zegt niets over de payload zelf.
    private struct CompressionRejected: Error {}

    private static let gzipDisabledKey = "syncGzipUnsupported"
    private static var gzipEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: gzipDisabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: gzipDisabledKey) }
    }

    private static func send(_ payload: Payload) async throws {
        guard let db = client else { return }
        let params = RPCParams(payload: payload)

        var compressionRejected = false
        if gzipEnabled, let body = try await gzipped(params) {
            do {
                try await postGzip("sync_push", body: body)
                return
            } catch is CompressionRejected {
                compressionRejected = true
            }
        }
        try await db.rpc("sync_push", params: params).execute()
        // Ongecomprimeerd lukt het wél, dus het lag aan de compressie en niet aan de
        // payload. Pas hier uitzetten: een 400 op een kapotte payload mag gzip niet
        // permanent uitschakelen.
        if compressionRejected { gzipEnabled = false }
    }

    /// JSON-encode + gzip op een achtergrond-thread. Dit is de zwaarste stap van een push
    /// en hoort niet op de MainActor.
    private static func gzipped(_ params: RPCParams) async throws -> Data? {
        try await Task.detached(priority: .utility) {
            Gzip.compress(try makeEncoder().encode(params))
        }.value
    }

    private static func postGzip(_ function: String, body: Data) async throws {
        guard let config, let client else { throw notConfigured() }
        let token = try await client.auth.session.accessToken
        var request = URLRequest(url: config.url.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return }
        // Een gateway die Content-Encoding niet doorlaat, struikelt op de body zelf.
        // 401/5xx zeggen niets over compressie en gaan als gewone fout door.
        if [400, 411, 415, 501].contains(code) { throw CompressionRejected() }
        let message = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
        throw NSError(domain: "Sync", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Pull (server wint, lokaal wordt vervangen)

    static func pull(_ context: ModelContext) async throws {
        let uid = try await userID()
        guard let db = client else { return }

        let profileRows: [ProfileRow] = try await db.from("profiles").select().eq("user_id", value: uid).execute().value
        guard let profileRow = profileRows.first else {
            pushAllowed = true // server is leeg → pushen kan geen data vernietigen
            return
        }

        let weights: [WeightRow] = try await db.from("weight_entries").select().eq("user_id", value: uid).execute().value
        let proteins: [ProteinRow] = try await db.from("protein_entries").select().eq("user_id", value: uid).execute().value
        let setRows: [SetRow] = try await db.from("set_entries").select().eq("user_id", value: uid).execute().value
        let habitRows: [HabitsRow] = try await db.from("day_habits").select().eq("user_id", value: uid).execute().value
        let routineRows: [RoutineRow] = try await db.from("routines").select().eq("user_id", value: uid).execute().value
        let mealRows: [MealRow] = try await db.from("meals").select().eq("user_id", value: uid).execute().value
        let foodRows: [FoodRow] = try await db.from("food_products").select().eq("user_id", value: uid).execute().value
        let exerciseRows: [ExerciseRow] = try await db.from("exercises").select().eq("user_id", value: uid).execute().value
        let scaleRows: [ScaleRow] = try await db.from("scales").select().eq("user_id", value: uid).execute().value
        let customRows: [CustomHabitRow] = try await db.from("custom_habits").select().eq("user_id", value: uid).execute().value
        let logRows: [HabitLogRow] = try await db.from("habit_logs").select().eq("user_id", value: uid).execute().value

        // Wissen en terugzetten in één transactie: wordt de app er middenin afgeschoten,
        // dan blijft de oude lokale staat staan i.p.v. een half gevulde database.
        try context.transaction {
            try wipeLocal(context)

            let profile = Profile(name: profileRow.name, age: profileRow.age, heightCm: profileRow.height_cm,
                                  startWeight: profileRow.start_weight, goalWeight: profileRow.goal_weight,
                                  goalDate: profileRow.goal_date, trainingsPerWeek: profileRow.trainings_per_week)
            profile.startDate = profileRow.start_date
            profile.tracksCreatine = profileRow.tracks_creatine
            profile.tracksSleep = profileRow.tracks_sleep
            profile.trainingDays = profileRow.training_days
            profile.kcalTarget = profileRow.kcal_target
            profile.schedule = profileRow.schedule
            profile.tracksFood = profileRow.tracks_food ?? true
            context.insert(profile)

            for r in weights { context.insert(WeightEntry(date: r.date, kg: r.kg, scale: r.scale)) }
            for r in proteins {
                context.insert(ProteinEntry(date: r.date, grams: r.grams, label: r.label,
                                            kcal: r.kcal, carbs: r.carbs, fat: r.fat, meal: r.meal,
                                            amount: r.amount ?? 0,
                                            unit: FoodUnit(rawValue: r.unit ?? "g") ?? .gram))
            }
            for r in setRows { context.insert(SetEntry(date: r.date, exercise: r.exercise, weightKg: r.weight_kg, reps: r.reps,
                                                        dropset: r.dropset ?? false, failure: r.failure ?? false,
                                                        seconds: r.seconds ?? 0)) }
            for r in habitRows {
                let h = DayHabits(date: r.date, creatine: r.creatine, sleptEnough: r.slept_enough)
                h.note = r.note
                h.bedTime = r.bed_time
                h.wakeTime = r.wake_time
                h.sleepQuality = r.sleep_quality
                h.journal = r.journal ?? []
                h.workoutNote = r.workout_note ?? ""
                h.energy = r.energy ?? 0
                h.mood = r.mood ?? 0
                h.soreness = r.soreness ?? 0
                h.stress = r.stress ?? 0
                h.exerciseNotes = r.exercise_notes ?? [:]
                context.insert(h)
            }
            for r in routineRows {
                let routine = Routine(name: r.name, exercises: r.exercises)
                routine.alternatives = r.alternatives
                routine.targets = r.targets
                routine.supersets = r.supersets
                routine.restByExercise = r.rest_by_exercise
                routine.createdAt = r.created_at
                context.insert(routine)
            }
            for r in mealRows {
                let meal = Meal(name: r.name, protein: r.protein, kcal: r.kcal)
                meal.createdAt = r.created_at
                meal.servings = r.servings
                meal.ingredients = r.ingredients
                meal.favorite = r.favorite
                context.insert(meal)
            }
            for r in foodRows {
                let f = FoodProduct(name: r.name, brand: r.brand, barcode: r.barcode,
                                    protein100: r.protein100, kcal100: r.kcal100,
                                    carbs100: r.carbs100, fat100: r.fat100)
                f.favorite = r.favorite
                f.imageURL = r.image_url
                f.servingGrams = r.serving_grams
                f.servingName = r.serving_name
                f.createdAt = r.created_at
                f.unit = r.unit ?? FoodUnit.gram.rawValue
                f.lastAmount = r.last_amount ?? 0
                f.categories = r.categories ?? ""
                context.insert(f)
            }
            for r in exerciseRows {
                let ex = Exercise(name: r.name, muscle: r.muscle, type: r.type)
                ex.createdAt = r.created_at
                context.insert(ex)
            }
            for r in scaleRows {
                context.insert(Scale(name: r.name))
            }
            for r in customRows {
                let habit = CustomHabit(name: r.name)
                habit.createdAt = r.created_at
                context.insert(habit)
            }
            for r in logRows { context.insert(HabitLog(name: r.name, date: r.date)) }
        }

        lastPushedHash = try await fingerprint(collect(context))
        pushAllowed = true
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")
    }

    /// Volledige data als JSON — back-up/portabiliteit los van de server.
    static func exportJSON(_ context: ModelContext) -> String? {
        guard let p = try? collect(context) else { return nil }
        let encoder = makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

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
    }

    /// Uitloggen. Met keepLocalData blijft alles op het toestel staan (en gaat verder
    /// onder een nieuw anoniem account); anders wordt het toestel leeggemaakt en
    /// blijft je data alleen op je account staan.
    static func signOut(context: ModelContext, keepLocalData: Bool) async {
        try? await client?.auth.signOut()
        pushAllowed = false
        lastPushedHash = nil // ander account mag nooit als "ongewijzigd" tellen
        pushFailures = 0
        retryPushAfter = nil // ander account = schone lei, niet wachten op een oude storing
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = nil
        UserDefaults.standard.removeObject(forKey: "lastSync")
        if !keepLocalData {
            try? wipeLocal(context)
        }
        await bootstrap(context)
    }

    // MARK: - Bootstrap: bepaal veilig of auto-push mag

    /// Voorkomt dat een verse (bijna lege) install de server overschrijft.
    static func bootstrap(_ context: ModelContext) async {
        guard isConfigured else { return }
        do {
            let uid = try await userID()
            let serverProfiles: [ProfileRow] = try await client!.from("profiles").select().eq("user_id", value: uid).execute().value
            let localProfile = try context.fetch(FetchDescriptor<Profile>()).first

            if serverProfiles.isEmpty {
                pushAllowed = true
            } else if localProfile == nil {
                try await pull(context)
            } else if abs(localProfile!.startDate.timeIntervalSince(serverProfiles[0].start_date)) < 1 {
                pushAllowed = true // zelfde profiel-lijn → veilig
            } else {
                pushAllowed = false
                SyncStatus.shared.lastError = "De server bevat andere data dan dit toestel. Kies in Profiel: 'Data ophalen van server' (server wint) of 'Sync nu' (dit toestel wint)."
            }
        } catch {
            SyncStatus.shared.lastError = "Sync-check mislukt: \(error.localizedDescription)"
        }
    }

    // MARK: - Account (e-mail + wachtwoord of Google)

    static var currentEmail: String? {
        client?.auth.currentSession?.user.email
    }

    static var isAnonymous: Bool {
        client?.auth.currentSession?.user.isAnonymous ?? true
    }

    /// Actieve sessie? Na registreren met e-mailbevestiging-aan is die er nog niet.
    static var hasSession: Bool {
        client?.auth.currentSession != nil
    }

    private static func notConfigured() -> Error {
        NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supabase niet geconfigureerd — vul Built/Secrets.plist in."])
    }

    /// Registreren. Anoniem account met data → wordt geconverteerd (zelfde user, data blijft).
    static func register(email: String, password: String, context: ModelContext) async throws {
        guard let client else { throw notConfigured() }
        let session = try? await client.auth.session
        if session?.user.isAnonymous == true {
            try await client.auth.update(user: UserAttributes(email: email, password: password))
        } else {
            try await client.auth.signUp(email: email, password: password)
        }
        SyncStatus.shared.lastError = nil
        await bootstrap(context)
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
        pushAllowed = false
        lastPushedHash = nil
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
        pushAllowed = false
        lastPushedHash = nil
        SyncStatus.shared.lastError = nil
        await bootstrap(context)
    }

    /// Verwijdert het account volledig: alle serverdata + de auth-user (via RPC met
    /// verhoogde rechten), daarna het toestel leegmaken. Onomkeerbaar.
    static func deleteAccount(context: ModelContext) async throws {
        guard let client else { throw notConfigured() }
        try await client.rpc("delete_account").execute()
        // Server-account is weg; signOut ruimt de lokale sessie op, wist het toestel
        // en start een verse anonieme lijn zodat de app bruikbaar blijft.
        await signOut(context: context, keepLocalData: false)
    }

    // MARK: - Automatische sync-lus

    /// Vingerafdruk van de laatst geslaagde push, in UserDefaults zodat hij een herstart
    /// overleeft. Zonder dat begon elke koude start op `nil` en pushte de app binnen
    /// twintig seconden de volledige database, ook als er niets gewijzigd was.
    private static let hashKey = "lastPushedHash"
    private static var lastPushedHash: String? {
        get { UserDefaults.standard.string(forKey: hashKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: hashKey) }
            else { UserDefaults.standard.removeObject(forKey: hashKey) }
        }
    }

    private static var running = false
    private(set) static var pushAllowed = false
    static var appActive = true

    /// Gaat aan bij elke lokale wijziging. Zonder deze vlag draaide de lus élke ronde
    /// `collect()` — twaalf volledige fetches plus een JSON-encode van de complete
    /// database, ook als er niets veranderd was.
    private static var dirty = true

    /// Bij een mislukte push wachten we langer dan het vaste interval. Zonder deze rem
    /// blijft een langdurige storing (offline, server plat) elke ronde hameren.
    private static var pushFailures = 0
    private static var retryPushAfter: Date?

    /// Laat de sync-lus weten dat er iets te pushen valt.
    static func markDirty() { dirty = true }

    /// Encoder voor de vingerafdruk, de gzip-body en de export.
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

    /// SHA-256 over de payload, als hex.
    ///
    /// Swift's `Hasher` kan dit niet: die is per proces willekeurig geseed, dus dezelfde
    /// data levert na een herstart een andere waarde — precies wat je niet wil van iets
    /// dat je in UserDefaults bewaart.
    nonisolated static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func digest(_ p: Payload) throws -> String {
        hexDigest(try makeEncoder().encode(p))
    }

    /// Encoden en hashen van de complete database op de MainActor gaf een merkbare stall.
    /// Payload is een boom van waardetypes, dus hij mag mee naar een achtergrond-task.
    private static func fingerprint(_ p: Payload) async throws -> String {
        try await Task.detached(priority: .utility) { try digest(p) }.value
    }

    /// Interval van de achtergrond-lus.
    ///
    /// Stond op 20 seconden. Tijdens een training vink je continu sets af, dus stond
    /// `dirty` permanent aan en pushte hij ~180 keer per training de volledige historie.
    /// De sync is een back-up, geen live-opslag: SwiftData is al duurzaam en een
    /// force-quit midden in een training verliest niets (`draftSnapshot` vangt dat af).
    private static let interval: Duration = .seconds(300)

    static func start(_ context: ModelContext) {
        guard isConfigured, !running else { return }
        running = true
        // SwiftData meldt elke save; dat is precies "er valt iets te pushen".
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { markDirty() }
        }
        Task {
            while true {
                try? await Task.sleep(for: interval)
                guard appActive else { continue } // ponytail: niet stampen in de achtergrond
                await pushIfChanged(context)
            }
        }
    }

    /// `force` markeert een bewust moment: einde training, of de app die naar de
    /// achtergrond gaat. Die mogen ook tijdens een training pushen. De lus niet — die zou
    /// anders elke ronde de volledige historie versturen zolang je aan het afvinken bent.
    static func pushIfChanged(_ context: ModelContext, force: Bool = false) async {
        guard pushAllowed, dirty else { return }
        guard force || WorkoutStatus.shared.startedAt == nil else { return }
        if let retryPushAfter, Date.now < retryPushAfter { return }
        do {
            let h = try await fingerprint(collect(context))
            // Niets veranderd t.o.v. de server: schoon, dus de vlag mag uit.
            guard h != lastPushedHash else { dirty = false; return }
            try await push(context)
            // Pas hier uit: bij een fout blijft 'dirty' staan zodat de lus het opnieuw
            // probeert, ook als de gebruiker daarna niets meer wijzigt.
            dirty = false
        } catch {
            pushFailures += 1
            retryPushAfter = .now.addingTimeInterval(min(20 * pow(2, Double(pushFailures)), 600))
            SyncStatus.shared.lastError = "Sync mislukt: \(error.localizedDescription)"
        }
    }
}
