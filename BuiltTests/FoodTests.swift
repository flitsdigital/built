import Foundation
import SwiftData
import Testing
@testable import Built

/// Herschalen is de enige plek waar macro's worden omgerekend: "250 → 200 g" mag geen
/// calorieën uit het niets laten ontstaan, en oudere invoer zonder portie mag er niet
/// door kapot.
@Suite("Porties herschalen")
struct ProteinEntryTests {
    let context: ModelContext

    init() throws {
        context = try memoryContext()
    }

    /// 250 g kwark: 25 g eiwit, 150 kcal, 10 g koolhydraten, 5 g vet.
    func kwark(amount: Double = 250) -> ProteinEntry {
        let entry = ProteinEntry(grams: 25, label: "Kwark", kcal: 150, carbs: 10, fat: 5, amount: amount)
        context.insert(entry)
        return entry
    }

    @Test("per100 rekent de portie terug naar 100 g")
    func per100() throws {
        let waarden = try #require(kwark().per100)
        #expect(abs(waarden.protein - 10) < 1e-9)
        #expect(abs(waarden.kcal - 60) < 1e-9)
        #expect(abs(waarden.carbs - 4) < 1e-9)
        #expect(abs(waarden.fat - 2) < 1e-9)
    }

    @Test("Herschalen naar 200 g schaalt alle macro's mee")
    func naarTweehonderd() {
        let entry = kwark()
        entry.rescale(to: 200)
        #expect(entry.amount == 200)
        #expect(entry.grams == 20)
        #expect(entry.kcal == 120)
        #expect(entry.carbs == 8)
        #expect(entry.fat == 4)
    }

    @Test("250 → 200 → 250 komt exact terug")
    func heenEnTerug() {
        let entry = kwark()
        entry.rescale(to: 200)
        entry.rescale(to: 250)
        #expect(entry.amount == 250)
        #expect(entry.grams == 25)
        #expect(entry.kcal == 150)
        #expect(entry.carbs == 10)
        #expect(entry.fat == 5)
    }

    @Test("Zonder portie is er niets om terug te rekenen")
    func oudereInvoerZonderPortie() {
        let oud = kwark(amount: 0) // zoals gelogd vóór de porties bestonden
        #expect(oud.per100 == nil)

        oud.rescale(to: 200)
        #expect(oud.amount == 0)
        #expect(oud.grams == 25) // macro's blijven staan, niets stiekem herrekend
        #expect(oud.kcal == 150)
    }

    @Test("Herschalen naar 0 of minder wordt genegeerd")
    func nulWordtGenegeerd() {
        let entry = kwark()
        entry.rescale(to: 0)
        #expect(entry.amount == 250)
        #expect(entry.grams == 25)

        entry.rescale(to: -100)
        #expect(entry.amount == 250)
        #expect(entry.grams == 25)
    }

    @Test("Milliliters werken hetzelfde als grammen")
    func milliliters() {
        let melk = ProteinEntry(grams: 9, label: "Melk", kcal: 115, carbs: 12, fat: 4,
                                amount: 250, unit: .milliliter)
        context.insert(melk)
        #expect(melk.foodUnit == .milliliter)
        melk.rescale(to: 500)
        #expect(melk.grams == 18)
        #expect(melk.kcal == 230)
        #expect(melk.foodUnit == .milliliter) // eenheid blijft, alleen de hoeveelheid schuift
    }

    @Test("Herschalen rondt af op hele grammen")
    func afronding() {
        let entry = ProteinEntry(grams: 7, label: "Noten", kcal: 65, amount: 30)
        context.insert(entry)
        entry.rescale(to: 10) // 7/3 = 2,33 → 2
        #expect(entry.grams == 2)
        #expect(entry.kcal == 22) // 65/3 = 21,67 → 22
    }
}

/// ml-vs-gram wordt geraden uit de OpenFoodFacts-categorieën. Zit die gok ernaast, dan log
/// je een glas melk in grammen — categorieën hieronder zijn de echte tags van die producten.
@Suite("Eenheid en porties")
struct FoodUnitTests {
    @Test("Drank wordt milliliters")
    func drankIsMl() {
        #expect(FoodUnit.detect(categories: ["en:dairies", "en:milks"], name: "Halfvolle melk") == .milliliter)
        #expect(FoodUnit.detect(categories: ["en:beverages", "en:carbonated-drinks"], name: "Cola") == .milliliter)
        #expect(FoodUnit.detect(categories: ["en:beverages", "en:waters"], name: "Bronwater") == .milliliter)
    }

    @Test("Vast voedsel blijft grammen")
    func vastIsGram() {
        #expect(FoodUnit.detect(categories: ["en:dairies", "en:fermented-foods"], name: "Magere kwark") == .gram)
        #expect(FoodUnit.detect(categories: ["en:plant-based-foods", "en:breads"], name: "Volkorenbrood") == .gram)
        #expect(FoodUnit.detect(categories: ["en:meats"], name: "Kipfilet") == .gram)
    }

    @Test("Zonder categorieën beslist de naam")
    func eigenProductenOpNaam() {
        #expect(FoodUnit.detect(categories: [], name: "Melk") == .milliliter)
        #expect(FoodUnit.detect(categories: [], name: "Verse jus") == .milliliter)
        #expect(FoodUnit.detect(categories: [], name: "Zwarte koffie") == .milliliter)
        #expect(FoodUnit.detect(categories: [], name: "Kwark") == .gram)
        #expect(FoodUnit.detect(categories: [], name: "Kipfilet") == .gram)
    }

    @Test("Bekende categorieën winnen van de naam")
    func categorieWintVanNaam() {
        // Melkchocolade is geen drank; omdat de categorieën bekend zijn wordt de naam
        // niet meer geraadpleegd en blijft het gram.
        #expect(FoodUnit.detect(categories: ["en:snacks", "en:chocolates"], name: "Melkchocolade") == .gram)
    }

    @Test("Drank krijgt glazen, blikjes en flessen")
    func drinkPorties() {
        let porties = FoodPortions.suggested(unit: .milliliter, categories: ["en:beverages"], name: "Cola")
        #expect(porties.map(\.label) == ["Klein glas", "1 glas", "Groot glas", "Blikje", "Fles"])
        #expect(porties.first { $0.label == "1 glas" }?.amount == 250)
    }

    @Test("Brood krijgt sneetjes")
    func broodPorties() {
        let porties = FoodPortions.suggested(unit: .gram,
                                             categories: ["en:plant-based-foods", "en:breads"],
                                             name: "Volkorenbrood")
        #expect(porties.first?.label == "1 snee")
        #expect(porties.first?.amount == 35)
    }

    @Test("Kwark krijgt bakjes")
    func kwarkPorties() {
        let porties = FoodPortions.suggested(unit: .gram,
                                             categories: ["en:dairies", "en:fermented-foods"],
                                             name: "Magere kwark")
        #expect(porties.first?.label == "1 bakje")
        #expect(porties.first?.amount == 150)
    }

    @Test("Boter en pindakaas krijgen lepels")
    func lepelPorties() {
        let porties = FoodPortions.suggested(unit: .gram, categories: ["en:dairies"], name: "Roomboter")
        #expect(porties.map(\.label) == ["1 tl", "1 el"])
    }

    @Test("Eieren krijgen stuks")
    func eiPorties() {
        let porties = FoodPortions.suggested(unit: .gram, categories: ["en:eggs"], name: "Scharrelei")
        #expect(porties.first?.amount == 60)
    }

    @Test("Onbekend product valt terug op 50/100/250 g")
    func genericPorties() {
        let porties = FoodPortions.suggested(unit: .gram, categories: ["en:meats"], name: "Kipfilet")
        #expect(porties.map(\.amount) == [50, 100, 250])
    }

    @Test("De eenheid gaat voor de categorie")
    func eenheidWint() {
        // Drinkyoghurt is zuivel én drank: de ml-eenheid bepaalt dat je glazen krijgt.
        let porties = FoodPortions.suggested(unit: .milliliter, categories: ["en:dairies"],
                                             name: "Drinkyoghurt")
        #expect(porties.first?.label == "Klein glas")
    }
}
