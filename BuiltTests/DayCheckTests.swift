import Foundation
import SwiftData
import Testing
@testable import Built

/// `DayCheck` is de enige definitie van "hoe goed was deze dag": score, streak en beide
/// heatmaps leiden hier alles uit af. Eén weging verkeerd = alles verkeerd, en je ziet het
/// nergens knallen — vandaar dat de weging hier expliciet wordt vastgelegd.
@Suite("Groei Score")
struct DayCheckTests {
    let context: ModelContext
    let profile: Profile
    /// Maandag 2 juni 2025 en de zondag ervoor: vaste dagen, zodat de weekdag-logica
    /// (rustdag ja/nee) niet van de kalender van vandaag afhangt.
    let maandag = nlDate(2025, 6, 2)
    let zondag = nlDate(2025, 6, 1)

    init() throws {
        context = try memoryContext()
        // Doelgewicht 62,5 kg → eiwitdoel precies 100 g, dus `protein:` leest als procenten.
        profile = Profile(name: "Jordi", age: 30, heightCm: 180, startWeight: 60,
                          goalWeight: 62.5, goalDate: nlDate(2026, 1, 1), trainingsPerWeek: 4)
        context.insert(profile)
    }

    /// Eén dag in de index met precies de vinkjes die je meegeeft.
    func index(_ day: Date, protein: Int = 0, trained: Bool = false, weighed: Bool = false,
               creatine: Bool = false, slept: Bool = false, habits: [String] = []) -> DayIndex {
        let proteins = store(protein > 0 ? [ProteinEntry(date: day, grams: protein, label: "Kwark")] : [],
                             in: context)
        let weights = store(weighed ? [WeightEntry(date: day, kg: 80)] : [], in: context)
        let sets = store(trained ? [SetEntry(date: day, exercise: "Squat", weightKg: 60, reps: 5)] : [],
                         in: context)
        let dayHabits = store([DayHabits(date: day, creatine: creatine, sleptEnough: slept)], in: context)
        let logs = store(habits.map { HabitLog(name: $0, date: day) }, in: context)
        return DayIndex(proteins: proteins, weights: weights, sets: sets,
                        habits: dayHabits, habitLogs: logs)
    }

    /// Alles binnen, voor elk van de meegegeven dagen.
    func perfectIndex(_ days: [Date]) -> DayIndex {
        let proteins = store(days.map { ProteinEntry(date: $0, grams: 100, label: "Kwark") }, in: context)
        let weights = store(days.map { WeightEntry(date: $0, kg: 80) }, in: context)
        let sets = store(days.map { SetEntry(date: $0, exercise: "Squat", weightKg: 60, reps: 5) }, in: context)
        let habits = store(days.map { DayHabits(date: $0, creatine: true, sleptEnough: true) }, in: context)
        return DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits)
    }

    // MARK: Weging

    @Test("Eiwitdoel is 1,6 g per kg doelgewicht")
    func eiwitdoel() {
        #expect(profile.proteinTarget == 100) // 1,6 × 62,5
    }

    @Test("Weging: 30 eiwit, 25 training, 15 gewicht, 15 creatine, 15 slaap")
    func wegingKlopt() {
        let factors = DayCheck.factors(maandag, index: index(maandag), profile: profile)
        #expect(factors.map(\.name) == ["Eiwit", "Training", "Gewicht", "Creatine", "Slaap"])
        #expect(factors.map(\.weight) == [30, 25, 15, 15, 15])
        #expect(factors.reduce(0) { $0 + $1.weight } == 100)
    }

    @Test("Lege dag scoort 0 en is niet perfect")
    func legeDag() {
        let leeg = index(maandag)
        #expect(DayCheck.score(maandag, index: leeg, profile: profile) == 0)
        #expect(DayCheck.perfect(maandag, index: leeg, profile: profile) == false)
    }

    @Test("Alles binnen is 100 en perfect")
    func volleDag() {
        let vol = index(maandag, protein: 100, trained: true, weighed: true, creatine: true, slept: true)
        #expect(DayCheck.score(maandag, index: vol, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: vol, profile: profile))
    }

    @Test("Eiwit telt naar rato, de rest is alles-of-niets")
    func eiwitNaarRato() {
        let half = index(maandag, protein: 50)
        let eiwit = DayCheck.factors(maandag, index: half, profile: profile)[0]
        #expect(abs(eiwit.progress - 0.5) < 1e-9)
        #expect(eiwit.done == false)
        #expect(DayCheck.score(maandag, index: half, profile: profile) == 15) // 30 × 0,5

        let halfPlusWeging = index(maandag, protein: 50, weighed: true)
        #expect(DayCheck.score(maandag, index: halfPlusWeging, profile: profile) == 30) // 15 + 15
    }

    @Test("Eiwit boven het doel telt niet dubbel")
    func eiwitGecapt() {
        let veel = index(maandag, protein: 300)
        #expect(DayCheck.factors(maandag, index: veel, profile: profile)[0].progress == 1)
        #expect(DayCheck.score(maandag, index: veel, profile: profile) == 30)
    }

    // MARK: Rustdagen

    @Test("Geplande rustdag telt als training gedaan")
    func rustdagTeltAlsTraining() {
        profile.trainingDays = [2, 3, 4, 5, 6] // ma t/m vr
        #expect(nlCalendar.component(.weekday, from: zondag) == 1)

        let zonderTraining = DayCheck.factors(zondag, index: index(zondag), profile: profile)
        #expect(zonderTraining.first { $0.name == "Training" }?.done == true)
        // ...en dus 25 punten, zonder ook maar één set.
        #expect(DayCheck.score(zondag, index: index(zondag), profile: profile) == 25)
    }

    @Test("Geplande trainingsdag zonder training telt niet mee")
    func gemisteTrainingsdag() {
        profile.trainingDays = [2, 3, 4, 5, 6]
        let factors = DayCheck.factors(maandag, index: index(maandag), profile: profile)
        #expect(factors.first { $0.name == "Training" }?.done == false)
    }

    @Test("Zonder vaste trainingsdagen telt alleen een echte training")
    func geenVasteDagen() {
        #expect(profile.trainingDays.isEmpty)
        let rust = DayCheck.factors(zondag, index: index(zondag), profile: profile)
        #expect(rust.first { $0.name == "Training" }?.done == false)

        let getraind = DayCheck.factors(zondag, index: index(zondag, trained: true), profile: profile)
        #expect(getraind.first { $0.name == "Training" }?.done == true)
    }

    // MARK: Eigen gewoontes

    @Test("Custom habits tellen mee voor 10 punten elk")
    func customHabits() {
        let namen = ["Lezen", "Mediteren"]
        let factors = DayCheck.factors(maandag, index: index(maandag), profile: profile, customHabits: namen)
        #expect(Array(factors.map(\.name).suffix(2)) == ["Lezen", "Mediteren"])
        #expect(factors.reduce(0) { $0 + $1.weight } == 120)
    }

    @Test("Een openstaande custom habit blokkeert de perfecte dag")
    func customHabitBlokkeert() {
        let namen = ["Lezen"]
        let zonder = index(maandag, protein: 100, trained: true, weighed: true, creatine: true, slept: true)
        #expect(DayCheck.score(maandag, index: zonder, profile: profile, customHabits: namen) == 91) // 100/110
        #expect(DayCheck.perfect(maandag, index: zonder, profile: profile, customHabits: namen) == false)

        let met = index(maandag, protein: 100, trained: true, weighed: true, creatine: true,
                        slept: true, habits: namen)
        #expect(DayCheck.score(maandag, index: met, profile: profile, customHabits: namen) == 100)
        #expect(DayCheck.perfect(maandag, index: met, profile: profile, customHabits: namen))
    }

    // MARK: Uitgeschakelde tracking

    @Test("Uitgezette tracking valt uit de weging, in plaats van als gemist te tellen")
    func uitgezetteTrackingTeltNietAlsGemist() {
        let dag = index(maandag, protein: 100, trained: true, weighed: true) // creatine + slaap open
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 70)

        profile.tracksCreatine = false
        profile.tracksSleep = false
        let factors = DayCheck.factors(maandag, index: dag, profile: profile)
        #expect(factors.map(\.name) == ["Eiwit", "Training", "Gewicht"])
        #expect(factors.reduce(0) { $0 + $1.weight } == 70)
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: dag, profile: profile))
    }

    @Test("Eten uit haalt het eiwitvinkje weg zonder de dag te straffen")
    func etenUit() {
        let dag = index(maandag, trained: true, weighed: true, creatine: true, slept: true) // niets gegeten
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 70)

        profile.tracksFood = false
        let factors = DayCheck.factors(maandag, index: dag, profile: profile)
        #expect(factors.contains { $0.name == "Eiwit" } == false)
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: dag, profile: profile))
    }

    /// Twee losse knoppen, want het zijn twee wensen: eten helemáál niet volgen, of eten
    /// wél loggen maar niet elke dag — en dan geen 30 punten verliezen op een dag dat het
    /// er niet van kwam.
    @Test("Eten telt niet mee voor de score terwijl je het wel blijft bijhouden")
    func etenTeltNietMee() {
        let dag = index(maandag, trained: true, weighed: true, creatine: true, slept: true) // niets gegeten
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 70)

        profile.foodCountsForScore = false
        // Eten blijft aan: de Eten-tab en de eiwitkaart op het dashboard hangen hieraan.
        #expect(profile.tracksFood)
        #expect(profile.foodInScore == false)

        let factors = DayCheck.factors(maandag, index: dag, profile: profile)
        #expect(factors.contains { $0.name == "Eiwit" } == false)
        // Niet meetellen is iets anders dan gemist: de factor valt uit de lijst en de
        // weging herverdeelt zich over wat er wél in zit.
        #expect(factors.map(\.name) == ["Training", "Gewicht", "Creatine", "Slaap"])
        #expect(factors.map(\.weight) == [25, 15, 15, 15])
        #expect(factors.reduce(0) { $0 + $1.weight } == 70)
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: dag, profile: profile))
    }

    @Test("Gelogd eiwit levert geen punten meer op als eten niet meetelt")
    func etenTeltNietMeeOokNietBijInvoer() {
        profile.foodCountsForScore = false
        let alleenEiwit = index(maandag, protein: 100)
        #expect(DayCheck.score(maandag, index: alleenEiwit, profile: profile) == 0)
    }

    @Test("Eten telt standaard mee")
    func etenTeltStandaardMee() {
        #expect(profile.foodCountsForScore)
        #expect(profile.foodInScore)
    }

    @Test("Eten bijhouden uit weegt zwaarder dan de score-knop")
    func etenUitOverruleertScoreKnop() {
        profile.tracksFood = false
        profile.foodCountsForScore = true
        #expect(profile.foodInScore == false)
        #expect(DayCheck.factors(maandag, index: index(maandag), profile: profile)
            .contains { $0.name == "Eiwit" } == false)
    }

    @Test("Alle tracking uit laat training en gewicht over")
    func alleTrackingUit() {
        profile.tracksFood = false
        profile.tracksCreatine = false
        profile.tracksSleep = false
        let factors = DayCheck.factors(maandag, index: index(maandag), profile: profile)
        #expect(factors.map(\.name) == ["Training", "Gewicht"])
        #expect(factors.reduce(0) { $0 + $1.weight } == 40)
        #expect(DayCheck.score(maandag, index: index(maandag, trained: true, weighed: true),
                               profile: profile) == 100)
    }

    // MARK: Perfect versus 100

    @Test("Een perfecte dag scoort altijd 100")
    func perfectImpliceertHonderd() {
        for eiwit in [0, 50, 99, 100, 250] {
            for extras in [false, true] {
                let dag = index(maandag, protein: eiwit, trained: extras, weighed: extras,
                                creatine: extras, slept: extras)
                if DayCheck.perfect(maandag, index: dag, profile: profile) {
                    #expect(DayCheck.score(maandag, index: dag, profile: profile) == 100)
                }
            }
        }
    }

    /// Andersom geldt het níét: 99 van 100 g eiwit levert 99,7 punten, en dat rondt af
    /// naar 100 terwijl het eiwitvinkje nog openstaat. Het dashboard zegt dan 100 terwijl
    /// de streak niet doorloopt. Gedrag vastgelegd, niet goedgekeurd — zie rapportage.
    /// 100 is gereserveerd voor een écht complete dag. Rondde de score af, dan zei het
    /// dashboard "Perfecte dag 🏆" bij 99 van 100 g eiwit terwijl de streak niet doorliep.
    @Test("Score 100 kan alleen bij een perfecte dag")
    func honderdBetekentPerfect() {
        let bijna = index(maandag, protein: 99, trained: true, weighed: true, creatine: true, slept: true)
        #expect(DayCheck.score(maandag, index: bijna, profile: profile) == 99)
        #expect(DayCheck.perfect(maandag, index: bijna, profile: profile) == false)

        let compleet = index(maandag, protein: 100, trained: true, weighed: true, creatine: true, slept: true)
        #expect(DayCheck.score(maandag, index: compleet, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: compleet, profile: profile) == true)
    }

    // MARK: Streak

    @Test("Streak telt aaneengesloten perfecte dagen; vandaag mag nog open staan")
    func streakLooptDoorOverEenOpenVandaag() {
        let index = perfectIndex([daysAgo(1), daysAgo(2)])
        #expect(DayCheck.streak(index: index, profile: profile) == 2)
    }

    @Test("Een gat breekt de streak")
    func streakBreekt() {
        let index = perfectIndex([daysAgo(0), daysAgo(2), daysAgo(3)])
        #expect(DayCheck.streak(index: index, profile: profile) == 1)
    }

    @Test("Zonder perfecte dagen is de streak 0")
    func streakLeeg() {
        #expect(DayCheck.streak(index: DayIndex(), profile: profile) == 0)
    }
}
