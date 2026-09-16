import Foundation
import SwiftData
import Testing
@testable import Built

@Suite("Recept van een link")
struct RecipeImportTests {
    /// Lekker en Simpel-achtig: Recipe in @graph, yield als array, geen nutrition.
    let graphHTML = """
    <html><head><title>x</title>
    <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage","name":"nope"},
    {"@type":"Recipe","name":"Lasagne &amp; salade","image":["https://img/1.jpg","https://img/2.jpg"],
    "recipeIngredient":["1  pakje lasagne bladen","400 gr tomatenblokjes"],"recipeYield":["4","4 personen"],
    "totalTime":"PT1H10M","recipeCuisine":"Italiaans","recipeCategory":["Hoofdgerecht","Pasta"]}]}</script>
    </head></html>
    """

    @Test("Recipe uit @graph, met arrays voor foto en porties")
    func graph() throws {
        let r = try #require(RecipeImport.parse(html: graphHTML))
        #expect(r.name == "Lasagne & salade")
        #expect(r.imageURL == "https://img/1.jpg")
        #expect(r.ingredients == ["1 pakje lasagne bladen", "400 gr tomatenblokjes"])
        #expect(r.servings == 4)
        #expect(r.minutes == 70)
        #expect(r.kcal == 0)
        #expect(r.labelSuggestions == ["italiaans", "hoofdgerecht", "pasta"])
    }

    @Test("Voedingswaarde en foto-object zoals AH ze stuurt")
    func nutrition() throws {
        let html = """
        <script type='application/ld+json'>{"@type":["Recipe"],"name":"Kip","image":{"@type":"ImageObject","url":"https://img/k.jpg"},
        "recipeYield":4,"nutrition":{"calories":"620 kcal","proteinContent":"38.4 g"}}</script>
        """
        let r = try #require(RecipeImport.parse(html: html))
        #expect(r.imageURL == "https://img/k.jpg")
        #expect(r.servings == 4)
        #expect(r.kcal == 620)
        #expect(r.protein == 38)
    }

    @Test("Zonder Recipe-data blijft alleen de og:title over")
    func fallback() throws {
        let html = #"<meta property="og:title" content="Klassieke lasagne" /><meta property="og:image" content="https://img/og.jpg" />"#
        let r = try #require(RecipeImport.parse(html: html))
        #expect(r.name == "Klassieke lasagne")
        #expect(r.imageURL == "https://img/og.jpg")
        #expect(r.ingredients.isEmpty)
        #expect(RecipeImport.parse(html: "<html></html>") == nil)
    }

    @Test("Bereidingsstappen in alle vormen die sites gebruiken")
    func steps() throws {
        let html = """
        <script type="application/ld+json">{"@type":"Recipe","name":"A","recipeInstructions":[
          {"@type":"HowToSection","name":"Saus","itemListElement":[{"@type":"HowToStep","text":"Ui snipperen. "},{"@type":"HowToStep","text":"Fruiten."}]},
          {"@type":"HowToStep","text":"Lagen bouwen."}]}</script>
        """
        #expect(try #require(RecipeImport.parse(html: html)).steps == ["Ui snipperen.", "Fruiten.", "Lagen bouwen."])
        let plain = #"<script type="application/ld+json">{"@type":"Recipe","name":"B","recipeInstructions":"Snijd.\nBak.\n"}</script>"#
        #expect(try #require(RecipeImport.parse(html: plain)).steps == ["Snijd.", "Bak."])
        let list = #"<script type="application/ld+json">{"@type":"Recipe","name":"C","recipeInstructions":["Een","Twee"]}</script>"#
        #expect(try #require(RecipeImport.parse(html: list)).steps == ["Een", "Twee"])
    }

    @Test("ISO-duur naar minuten")
    func duration() {
        #expect(RecipeImport.minutes("PT50M") == 50)
        #expect(RecipeImport.minutes("PT2H") == 120)
        #expect(RecipeImport.minutes("") == 0)
    }
}

@Suite("Ingrediëntregels")
struct DishIngredientTests {
    @Test("Hoeveelheid, eenheid en naam uit een regel", arguments: [
        ("400 g gehakt", 400.0, "g", "gehakt"),
        ("1,5 kg aardappelen", 1500.0, "g", "aardappelen"),
        ("2 el olijfolie", 30.0, "ml", "olijfolie"),
        ("250 ml room", 250.0, "ml", "room"),
        ("3 eieren", 3.0, "stuk", "eieren"),
        ("½ ui", 0.5, "stuk", "ui"),
        ("zout en peper", 0.0, "stuk", "zout en peper"),
        ("1-2 tenen knoflook", 1.0, "stuk", "tenen knoflook"),
    ])
    func parse(line: String, amount: Double, unit: String, name: String) {
        let p = DishIngredient.parse(line)
        #expect(abs(p.amount - amount) < 1e-9)
        #expect(p.unit == unit)
        #expect(p.name == name)
    }
}

@Suite("Macro's per portie")
struct DishMacrosTests {
    let context: ModelContext
    init() throws { context = try memoryContext() }

    func gehakt() -> FoodProduct {
        let p = FoodProduct(name: "Gehakt", protein100: 20, kcal100: 250)
        context.insert(p)
        return p
    }

    @Test("Niets gekoppeld en geen site-waarde → onbekend")
    func unknown() {
        let d = Dish(name: "Lasagne")
        d.ingredients = [DishIngredient(text: "400 g gehakt")]
        #expect(d.macros(products: []) == nil)
    }

    @Test("Site-waarde is de start; volledig gekoppeld wint")
    func siteThenLinked() {
        let d = Dish(name: "Lasagne")
        d.servings = 4
        d.siteKcal = 600; d.siteProtein = 30
        d.ingredients = [DishIngredient(text: "400 g gehakt"), DishIngredient(text: "zout")]
        let site = d.macros(products: [])
        #expect(site?.kcal == 600 && site?.complete == true)

        let p = gehakt()
        d.ingredients[0].productID = p.syncID
        // Half gekoppeld: site blijft de waarheid.
        #expect(d.macros(products: [p])?.kcal == 600)

        let zout = FoodProduct(name: "Zout", protein100: 0, kcal100: 0)
        context.insert(zout)
        d.ingredients[1].productID = zout.syncID
        let linked = d.macros(products: [p, zout])
        #expect(linked?.kcal == 250) // 400 g × 250/100 = 1000 kcal / 4 porties
        #expect(linked?.protein == 20)
        #expect(linked?.complete == true)
    }

    @Test("Half gekoppeld zonder site-waarde telt wat er is, als onvolledig")
    func partial() {
        let d = Dish(name: "Lasagne")
        d.servings = 2
        d.ingredients = [DishIngredient(text: "200 g gehakt"), DishIngredient(text: "zout")]
        let p = gehakt()
        d.ingredients[0].productID = p.syncID
        let m = d.macros(products: [p])
        #expect(m?.kcal == 250 && m?.complete == false)
    }

    @Test("Stuks gaan via de portiegrootte van het product")
    func pieces() {
        let d = Dish(name: "Omelet")
        d.servings = 1
        let ei = FoodProduct(name: "Ei", protein100: 13, kcal100: 150)
        ei.servingGrams = 60
        context.insert(ei)
        d.ingredients = [DishIngredient(text: "3 eieren")]
        d.ingredients[0].productID = ei.syncID
        #expect(d.macros(products: [ei])?.kcal == 270)
    }
}
