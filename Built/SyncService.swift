import Foundation
import SwiftData
import Supabase
import Observation
import AuthenticationServices
import UIKit

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
}

// Supabase is de source of truth: de app pusht wijzigingen automatisch en een lege
// install haalt alles op. Push gaat via één RPC (sync_push) die server-side in één
// transactie alles vervangt — geen half-gewiste tabellen bij netwerkuitval.
@MainActor
enum Sync {
    // MARK: - Rijen (kolomnamen = snake_case zoals in Postgres)

    private struct ProfileRow: Codable {
        var user_id: UUID; var name: String; var age: Int; var height_cm: Int
        var start_weight: Double; var goal_weight: Double
        var start_date: Date; var goal_date: Date; var trainings_per_week: Int
        var tracks_creatine: Bool
        var tracks_sleep: Bool
        var training_days: [Int]
        var kcal_target: Int
        var schedule: [String: String]
    }
    private struct WeightRow: Codable { var user_id: UUID; var date: Date; var kg: Double; var scale: String }
    private struct ProteinRow: Codable {
        var user_id: UUID; var date: Date; var grams: Int; var label: String
        var kcal: Int; var carbs: Int; var fat: Int; var meal: String
    }
    private struct FoodRow: Codable {
        var user_id: UUID; var name: String; var brand: String; var barcode: String
        var protein100: Double; var kcal100: Double; var carbs100: Double; var fat100: Double
        var favorite: Bool; var image_url: String
        var serving_grams: Double; var serving_name: String; var created_at: Date
    }
    private struct SetRow: Codable {
        var user_id: UUID; var date: Date; var exercise: String; var weight_kg: Double; var reps: Int
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var dropset: Bool? = false; var failure: Bool? = false
    }
    private struct HabitsRow: Codable {
        var user_id: UUID; var date: Date; var creatine: Bool; var slept_enough: Bool
        var note: String; var bed_time: Date?; var wake_time: Date?; var sleep_quality: Int
        // Optioneel zodat een pull werkt óók als de kolommen nog niet gemigreerd zijn.
        var journal: [JournalNote]? = []
        var workout_note: String? = ""
    }
    private struct RoutineRow: Codable {
        var user_id: UUID; var name: String; var exercises: [String]
        var alternatives: [String: [String]]; var targets: [String: [Int]]
        var supersets: [String: String]; var rest_by_exercise: [String: Int]; var created_at: Date
    }
    private struct MealRow: Codable {
        var user_id: UUID; var name: String; var protein: Int; var kcal: Int
        var created_at: Date; var servings: Double; var ingredients: [Ingredient]
        var favorite: Bool
    }
    private struct ScaleRow: Codable { var user_id: UUID; var name: String }
    private struct CustomHabitRow: Codable { var user_id: UUID; var name: String; var created_at: Date }
    private struct ExerciseRow: Codable { var user_id: UUID; var name: String; var muscle: String; var type: String; var created_at: Date }
    private struct HabitLogRow: Codable { var user_id: UUID; var name: String; var date: Date }

    private struct Payload: Codable {
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

    // MARK: - Client

    static let client: SupabaseClient? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String],
              let urlString = dict["SUPABASE_URL"], let key = dict["SUPABASE_ANON_KEY"],
              !urlString.isEmpty, !key.isEmpty, let supabaseURL = URL(string: urlString)
        else { return nil }
        return SupabaseClient(supabaseURL: supabaseURL, supabaseKey: key)
    }()

    static var isConfigured: Bool { client != nil }

    private static func userID() async throws -> UUID {
        guard let client else {
            throw NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supabase niet geconfigureerd — vul Built/Secrets.plist in."])
        }
        if let session = try? await client.auth.session {
            return session.user.id
        }
        return try await client.auth.signInAnonymously().user.id
    }

    // MARK: - Verzamelen (gesorteerd, zodat de change-hash stabiel is)

    private static func collect(_ context: ModelContext, uid: UUID) throws -> Payload {
        var p = Payload()
        if let profile = try context.fetch(FetchDescriptor<Profile>()).first {
            p.profile = ProfileRow(user_id: uid, name: profile.name, age: profile.age, height_cm: profile.heightCm,
                                   start_weight: profile.startWeight, goal_weight: profile.goalWeight,
                                   start_date: profile.startDate, goal_date: profile.goalDate,
                                   trainings_per_week: profile.trainingsPerWeek,
                                   tracks_creatine: profile.tracksCreatine, tracks_sleep: profile.tracksSleep,
                                   training_days: profile.trainingDays, kcal_target: profile.kcalTarget,
                                   schedule: profile.schedule)
        }
        p.weights = try context.fetch(FetchDescriptor<WeightEntry>(sortBy: [.init(\.date)]))
            .map { WeightRow(user_id: uid, date: $0.date, kg: $0.kg, scale: $0.scale) }
        p.proteins = try context.fetch(FetchDescriptor<ProteinEntry>(sortBy: [.init(\.date)]))
            .map { ProteinRow(user_id: uid, date: $0.date, grams: $0.grams, label: $0.label,
                              kcal: $0.kcal, carbs: $0.carbs, fat: $0.fat, meal: $0.meal) }
        p.sets = try context.fetch(FetchDescriptor<SetEntry>(sortBy: [.init(\.date)]))
            .map { SetRow(user_id: uid, date: $0.date, exercise: $0.exercise, weight_kg: $0.weightKg, reps: $0.reps,
                          dropset: $0.dropset, failure: $0.failure) }
        p.habits = try context.fetch(FetchDescriptor<DayHabits>(sortBy: [.init(\.date)]))
            .map { HabitsRow(user_id: uid, date: $0.date, creatine: $0.creatine, slept_enough: $0.sleptEnough,
                             note: $0.note, bed_time: $0.bedTime, wake_time: $0.wakeTime, sleep_quality: $0.sleepQuality,
                             journal: $0.journal, workout_note: $0.workoutNote) }
        p.routines = try context.fetch(FetchDescriptor<Routine>(sortBy: [.init(\.createdAt)]))
            .map { RoutineRow(user_id: uid, name: $0.name, exercises: $0.exercises,
                              alternatives: $0.alternatives, targets: $0.targets,
                              supersets: $0.supersets, rest_by_exercise: $0.restByExercise,
                              created_at: $0.createdAt) }
        p.meals = try context.fetch(FetchDescriptor<Meal>(sortBy: [.init(\.createdAt)]))
            .map { MealRow(user_id: uid, name: $0.name, protein: $0.protein, kcal: $0.kcal,
                           created_at: $0.createdAt, servings: $0.servings, ingredients: $0.ingredients,
                           favorite: $0.favorite) }
        p.foods = try context.fetch(FetchDescriptor<FoodProduct>(sortBy: [.init(\.createdAt)]))
            .map { FoodRow(user_id: uid, name: $0.name, brand: $0.brand, barcode: $0.barcode,
                           protein100: $0.protein100, kcal100: $0.kcal100,
                           carbs100: $0.carbs100, fat100: $0.fat100,
                           favorite: $0.favorite, image_url: $0.imageURL,
                           serving_grams: $0.servingGrams, serving_name: $0.servingName,
                           created_at: $0.createdAt) }
        p.exercises = try context.fetch(FetchDescriptor<Exercise>(sortBy: [.init(\.name)]))
            .map { ExerciseRow(user_id: uid, name: $0.name, muscle: $0.muscle, type: $0.type, created_at: $0.createdAt) }
        p.scales = try context.fetch(FetchDescriptor<Scale>(sortBy: [.init(\.name)]))
            .map { ScaleRow(user_id: uid, name: $0.name) }
        p.customHabits = try context.fetch(FetchDescriptor<CustomHabit>(sortBy: [.init(\.createdAt)]))
            .map { CustomHabitRow(user_id: uid, name: $0.name, created_at: $0.createdAt) }
        p.habitLogs = try context.fetch(FetchDescriptor<HabitLog>(sortBy: [.init(\.date)]))
            .map { HabitLogRow(user_id: uid, name: $0.name, date: $0.date) }
        return p
    }

    // MARK: - Push (atomair via RPC)

    static func push(_ context: ModelContext) async throws {
        let uid = try await userID()
        let p = try collect(context, uid: uid)
        guard let db = client else { return }
        struct Params: Encodable { let payload: Payload }
        do {
            try await db.rpc("sync_push", params: Params(payload: p)).execute()
        } catch {
            SyncStatus.shared.lastError = "Sync mislukt: \(error.localizedDescription)"
            throw error
        }
        lastPushedHash = try hash(p)
        pushAllowed = true // expliciete push = bewuste overschrijving
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")
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
        context.insert(profile)

        for r in weights { context.insert(WeightEntry(date: r.date, kg: r.kg, scale: r.scale)) }
        for r in proteins {
            context.insert(ProteinEntry(date: r.date, grams: r.grams, label: r.label,
                                        kcal: r.kcal, carbs: r.carbs, fat: r.fat, meal: r.meal))
        }
        for r in setRows { context.insert(SetEntry(date: r.date, exercise: r.exercise, weightKg: r.weight_kg, reps: r.reps,
                                                    dropset: r.dropset ?? false, failure: r.failure ?? false)) }
        for r in habitRows {
            let h = DayHabits(date: r.date, creatine: r.creatine, sleptEnough: r.slept_enough)
            h.note = r.note
            h.bedTime = r.bed_time
            h.wakeTime = r.wake_time
            h.sleepQuality = r.sleep_quality
            h.journal = r.journal ?? []
            h.workoutNote = r.workout_note ?? ""
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

        lastPushedHash = try hash(collect(context, uid: uid))
        pushAllowed = true
        SyncStatus.shared.lastError = nil
        SyncStatus.shared.lastSyncAt = .now
        UserDefaults.standard.set(Date.now.timeIntervalSinceReferenceDate, forKey: "lastSync")
    }

    /// Volledige data als JSON — back-up/portabiliteit los van de server.
    static func exportJSON(_ context: ModelContext) -> String? {
        guard let p = try? collect(context, uid: UUID()) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
        lastPushedHash = nil
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

    private static var lastPushedHash: Int?
    private static var running = false
    private(set) static var pushAllowed = false
    static var appActive = true

    private static func hash(_ p: Payload) throws -> Int {
        var hasher = Hasher()
        hasher.combine(try JSONEncoder().encode(p))
        return hasher.finalize()
    }

    static func start(_ context: ModelContext) {
        guard isConfigured, !running else { return }
        running = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard appActive else { continue } // ponytail: niet stampen in de achtergrond
                await pushIfChanged(context)
            }
        }
    }

    static func pushIfChanged(_ context: ModelContext) async {
        guard pushAllowed,
              let uid = try? await userID(),
              let p = try? collect(context, uid: uid),
              let h = try? hash(p),
              h != lastPushedHash else { return }
        try? await push(context)
    }
}
