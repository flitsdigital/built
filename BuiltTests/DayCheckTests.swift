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
    /// Maandag 2 juni 2025 en de zondag ervoor: vaste dagen, zodat niets van de kalender
    /// van vandaag afhangt.
    let maandag = nlDate(2025, 6, 2)
    let zondag = nlDate(2025, 6, 1)

    /// De week waarin `maandag` valt, via `Calendar.current` — daar rekent `WeekQuota` mee,
    /// en of een week op maandag of zondag begint hangt van de regio af.
    var week: DateInterval { Calendar.current.dateInterval(of: .weekOfYear, for: maandag)! }
    /// Middag, zodat een test niet op een middernacht-rand omvalt.
    func weekdag(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: week.start)!.addingTimeInterval(43_200)
    }

    init() throws {
        context = try memoryContext()
        // Doelgewicht 62,5 kg → eiwitdoel precies 100 g, dus `protein:` leest als procenten.
        // 7× per week: dan is elke dag een verplichte trainingsdag en meet de weging
        // hieronder alleen de weging, niet de weekstand. De rustdag-tests zetten 'm zelf lager.
        profile = Profile(name: "Jordi", age: 30, heightCm: 180, startWeight: 60,
                          goalWeight: 62.5, goalDate: nlDate(2026, 1, 1), trainingsPerWeek: 7)
        context.insert(profile)
    }

    /// Eén dag in de index met precies de vinkjes die je meegeeft.
    func index(_ day: Date, protein: Int = 0, trained: Bool = false, weighed: Bool = false,
               creatine: Bool = false, slept: Bool = false, checkedIn: Bool = false,
               habits: [String] = []) -> DayIndex {
        let proteins = store(protein > 0 ? [ProteinEntry(date: day, grams: protein, label: "Kwark")] : [],
                             in: context)
        let weights = store(weighed ? [WeightEntry(date: day, kg: 80)] : [], in: context)
        let sets = store(trained ? [SetEntry(date: day, exercise: "Squat", weightKg: 60, reps: 5)] : [],
                         in: context)
        let record = DayHabits(date: day, creatine: creatine, sleptEnough: slept)
        if checkedIn { record.energy = 3 } // één antwoord is genoeg, zie `checkedIn`
        let dayHabits = store([record], in: context)
        let logs = store(habits.map { HabitLog(name: $0, date: day) }, in: context)
        return DayIndex(proteins: proteins, weights: weights, sets: sets,
                        habits: dayHabits, habitLogs: logs)
    }

    /// Alles binnen, voor elk van de meegegeven dagen.
    func perfectIndex(_ days: [Date]) -> DayIndex {
        let proteins = store(days.map { ProteinEntry(date: $0, grams: 100, label: "Kwark") }, in: context)
        let weights = store(days.map { WeightEntry(date: $0, kg: 80) }, in: context)
        let sets = store(days.map { SetEntry(date: $0, exercise: "Squat", weightKg: 60, reps: 5) }, in: context)
        let habits = store(days.map { day -> DayHabits in
            let h = DayHabits(date: day, creatine: true, sleptEnough: true)
            h.energy = 3
            return h
        }, in: context)
        return DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits)
    }

    // MARK: Weging

    @Test("Eiwitdoel is 1,6 g per kg doelgewicht")
    func eiwitdoel() {
        #expect(profile.proteinTarget == 100) // 1,6 × 62,5
    }

    @Test("Weging: 30 eiwit, 25 training, 15 gewicht, 15 creatine, 15 slaap, 10 dagdetails")
    func wegingKlopt() {
        let factors = DayCheck.factors(maandag, index: index(maandag), profile: profile)
        #expect(factors.map(\.name) == ["Eiwit", "Training", "Gewicht", "Creatine", "Slaap", "Dagdetails"])
        #expect(factors.map(\.weight) == [30, 25, 15, 15, 15, 10])
        #expect(factors.reduce(0) { $0 + $1.weight } == 110)
    }

    @Test("Lege dag scoort 0 en is niet perfect")
    func legeDag() {
        let leeg = index(maandag)
        #expect(DayCheck.score(maandag, index: leeg, profile: profile) == 0)
        #expect(DayCheck.perfect(maandag, index: leeg, profile: profile) == false)
    }

    @Test("Alles binnen is 100 en perfect")
    func volleDag() {
        let vol = index(maandag, protein: 100, trained: true, weighed: true, creatine: true,
                        slept: true, checkedIn: true)
        #expect(DayCheck.score(maandag, index: vol, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: vol, profile: profile))
    }

    @Test("Eiwit telt naar rato, de rest is alles-of-niets")
    func eiwitNaarRato() {
        let half = index(maandag, protein: 50)
        let eiwit = DayCheck.factors(maandag, index: half, profile: profile)[0]
        #expect(abs(eiwit.progress - 0.5) < 1e-9)
        #expect(eiwit.done == false)
        #expect(DayCheck.score(maandag, index: half, profile: profile) == 14) // 30 × 0,5 van 110

        let halfPlusWeging = index(maandag, protein: 50, weighed: true)
        #expect(DayCheck.score(maandag, index: halfPlusWeging, profile: profile) == 27) // (15 + 15) van 110
    }

    @Test("Eiwit boven het doel telt niet dubbel")
    func eiwitGecapt() {
        let veel = index(maandag, protein: 300)
        #expect(DayCheck.factors(maandag, index: veel, profile: profile)[0].progress == 1)
        #expect(DayCheck.score(maandag, index: veel, profile: profile) == 27) // 30 van 110
    }

    // MARK: Rustdagen

    @Test("Rustdag zolang je je weekdoel nog kunt halen")
    func rustdagMetSpeling() {
        profile.trainingsPerWeek = 3
        let dag = weekdag(0) // eerste dag van de week: 7 dagen over voor 3 trainingen

        let zonderTraining = DayCheck.factors(dag, index: index(dag), profile: profile)
        #expect(zonderTraining.first { $0.name == "Training" }?.done == true)
        // ...en dus 25 van 110 punten, zonder ook maar één set.
        #expect(DayCheck.score(dag, index: index(dag), profile: profile) == 23)
    }

    @Test("Zonder speling is de dag verplicht")
    func laatsteDagIsVerplicht() {
        profile.trainingsPerWeek = 3
        let dag = weekdag(6) // laatste dag, nog 3 te gaan: dit kan niet meer goedkomen
        let factors = DayCheck.factors(dag, index: index(dag), profile: profile)
        #expect(factors.first { $0.name == "Training" }?.done == false)
    }

    @Test("Weekdoel gehaald maakt de rest van de week rustdag")
    func quotumGehaald() {
        profile.trainingsPerWeek = 2
        let sets = store([weekdag(0), weekdag(1)].map {
            SetEntry(date: $0, exercise: "Squat", weightKg: 60, reps: 5)
        }, in: context)
        let idx = DayIndex(proteins: [], weights: [], sets: sets, habits: [])

        let factors = DayCheck.factors(weekdag(6), index: idx, profile: profile)
        #expect(factors.first { $0.name == "Training" }?.done == true)
    }

    @Test("De speling loopt precies af als er nog net zoveel dagen als trainingen over zijn")
    func spelingKantelt() {
        let idx = index(maandag)
        // Doel 3, niets gedaan: dag 0 t/m 3 mag je nog overslaan, vanaf dag 4 (nog 3 over) niet meer.
        #expect(WeekQuota(weekdag(3), index: idx, target: 3).isRest)
        #expect(WeekQuota(weekdag(4), index: idx, target: 3).isRest == false)
        #expect(WeekQuota(weekdag(4), index: idx, target: 3).remaining == 3)
    }

    @Test("Zonder weekdoel telt alleen een echte training")
    func geenWeekdoel() {
        profile.trainingsPerWeek = 0
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
        #expect(factors.reduce(0) { $0 + $1.weight } == 130)
    }

    @Test("Een openstaande custom habit blokkeert de perfecte dag")
    func customHabitBlokkeert() {
        let namen = ["Lezen"]
        let zonder = index(maandag, protein: 100, trained: true, weighed: true, creatine: true,
                           slept: true, checkedIn: true)
        #expect(DayCheck.score(maandag, index: zonder, profile: profile, customHabits: namen) == 92) // 110/120
        #expect(DayCheck.perfect(maandag, index: zonder, profile: profile, customHabits: namen) == false)

        let met = index(maandag, protein: 100, trained: true, weighed: true, creatine: true,
                        slept: true, checkedIn: true, habits: namen)
        #expect(DayCheck.score(maandag, index: met, profile: profile, customHabits: namen) == 100)
        #expect(DayCheck.perfect(maandag, index: met, profile: profile, customHabits: namen))
    }

    // MARK: Uitgeschakelde tracking

    @Test("Uitgezette tracking valt uit de weging, in plaats van als gemist te tellen")
    func uitgezetteTrackingTeltNietAlsGemist() {
        let dag = index(maandag, protein: 100, trained: true, weighed: true, checkedIn: true) // creatine + slaap open
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 73) // 80 van 110

        profile.tracksCreatine = false
        profile.tracksSleep = false
        let factors = DayCheck.factors(maandag, index: dag, profile: profile)
        #expect(factors.map(\.name) == ["Eiwit", "Training", "Gewicht", "Dagdetails"])
        #expect(factors.reduce(0) { $0 + $1.weight } == 80)
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 100)
        #expect(DayCheck.perfect(maandag, index: dag, profile: profile))
    }

    @Test("Eten uit haalt het eiwitvinkje weg zonder de dag te straffen")
    func etenUit() {
        let dag = index(maandag, trained: true, weighed: true, creatine: true, slept: true,
                        checkedIn: true) // niets gegeten
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 73) // 80 van 110

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
        let dag = index(maandag, trained: true, weighed: true, creatine: true, slept: true,
                        checkedIn: true) // niets gegeten
        #expect(DayCheck.score(maandag, index: dag, profile: profile) == 73) // 80 van 110

        profile.foodCountsForScore = false
        // Eten blijft aan: de Eten-tab en de eiwitkaart op het dashboard hangen hieraan.
        #expect(profile.tracksFood)
        #expect(profile.foodInScore == false)

        let factors = DayCheck.factors(maandag, index: dag, profile: profile)
        #expect(factors.contains { $0.name == "Eiwit" } == false)
        // Niet meetellen is iets anders dan gemist: de factor valt uit de lijst en de
        // weging herverdeelt zich over wat er wél in zit.
        #expect(factors.map(\.name) == ["Training", "Gewicht", "Creatine", "Slaap", "Dagdetails"])
        #expect(factors.map(\.weight) == [25, 15, 15, 15, 10])
        #expect(factors.reduce(0) { $0 + $1.weight } == 80)
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
        #expect(factors.map(\.name) == ["Training", "Gewicht", "Dagdetails"])
        #expect(factors.reduce(0) { $0 + $1.weight } == 50)
        #expect(DayCheck.score(maandag, index: index(maandag, trained: true, weighed: true, checkedIn: true),
                               profile: profile) == 100)
    }

    // MARK: Perfect versus 100

    @Test("Een perfecte dag scoort altijd 100")
    func perfectImpliceertHonderd() {
        for eiwit in [0, 50, 99, 100, 250] {
            for extras in [false, true] {
                let dag = index(maandag, protein: eiwit, trained: extras, weighed: extras,
                                creatine: extras, slept: extras, checkedIn: extras)
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
        let bijna = index(maandag, protein: 99, trained: true, weighed: true, creatine: true,
                          slept: true, checkedIn: true)
        #expect(DayCheck.score(maandag, index: bijna, profile: profile) == 99)
        #expect(DayCheck.perfect(maandag, index: bijna, profile: profile) == false)

        let compleet = index(maandag, protein: 100, trained: true, weighed: true, creatine: true,
                             slept: true, checkedIn: true)
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

/// De vrije tekst van de check-in leeft in `journal`, het veld dat er al was. Die keuze
/// staat of valt met de vertaalslag ertussen: één notitie eruit halen en er één in
/// terugzetten, zonder dat er een tweede naast komt of een lege blijft staan.
@Suite("Check-in-notitie")
struct CheckInNoteTests {

    @Test("Leeg als er niets staat")
    func leeg() {
        #expect(DayHabits().checkInNote.isEmpty)
    }

    @Test("Tekst wordt één notitie")
    func schrijven() {
        let day = DayHabits()
        day.checkInNote = "Knie zeurde bij squats"
        #expect(day.journal.count == 1)
        #expect(day.checkInNote == "Knie zeurde bij squats")
    }

    /// Anders staat er na drie keer bijwerken een dagboek van drie regels waarvan er twee
    /// achterhaald zijn.
    @Test("Bijwerken vervangt dezelfde notitie")
    func bijwerken() {
        let day = DayHabits()
        day.checkInNote = "Eerste"
        let id = day.journal[0].id
        day.checkInNote = "Tweede"
        #expect(day.journal.count == 1)
        #expect(day.journal[0].id == id)
        #expect(day.checkInNote == "Tweede")
    }

    /// Een dag zonder tekst hoort geen lege rij in je historie te zijn.
    @Test("Leegmaken haalt de notitie weg")
    func wissen() {
        let day = DayHabits()
        day.checkInNote = "Iets"
        day.checkInNote = "   \n "
        #expect(day.journal.isEmpty)
        #expect(day.checkInNote.isEmpty)
    }

    @Test("Spaties eromheen tellen niet mee")
    func trimmen() {
        let day = DayHabits()
        day.checkInNote = "  Goed geslapen \n"
        #expect(day.checkInNote == "Goed geslapen")
    }

    /// De setter draait bij elke render van het tekstveld; zonder deze bewaking is elke
    /// render een wijziging, en dus een sync-push.
    @Test("Dezelfde tekst opnieuw zetten verandert niets")
    func geenLozeSchrijfactie() {
        let day = DayHabits()
        day.checkInNote = "Zelfde"
        let voor = day.journal[0]
        day.checkInNote = "Zelfde"
        #expect(day.journal == [voor])
    }
}
