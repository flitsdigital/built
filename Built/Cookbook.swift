import Foundation
import SwiftData
import UIKit

// MARK: - Kookboek
//
// Een Gerecht is iets anders dan een `Meal`: dat bestaat om te loggen, dit om te onthouden
// en te kiezen. Zie CONTEXT.md en docs/adr/0001. Loggen kan wél, maar via de gekoppelde
// producten en alleen als je erom vraagt.

/// Eén regel uit het recept. `text` is wat de site zei ("400 g gehakt"); `amount`/`unit`
/// zijn daaruit geraden en `productID` wijst naar een eigen `FoodProduct` zodra je 'm
/// gekoppeld hebt. Zonder koppeling telt de regel niet mee in de macro's.
struct DishIngredient: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var amount: Double = 0
    /// "g", "ml" of "stuk". Eetlepels en dergelijke zijn al naar ml omgerekend.
    var unit: String = "g"
    var productID: UUID? = nil

    init(text: String) {
        self.text = text
        let parsed = DishIngredient.parse(text)
        amount = parsed.amount
        unit = parsed.unit
    }

    /// Naam zonder hoeveelheid, als zoekterm voor de productzoeker: "400 g gehakt" → "gehakt".
    var searchTerm: String { DishIngredient.parse(text).name }

    /// "400 g gehakt" → 400 g; "2 el olie" → 30 ml; "3 eieren" → 3 stuk; "zout" → 0.
    /// Bewust klein: het hoeft niet alles te snappen, alleen genoeg dat je na het koppelen
    /// zelden de hoeveelheid nog hoeft te typen.
    static func parse(_ text: String) -> (amount: Double, unit: String, name: String) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, let amount = number(first) else {
            return (0, "stuk", text.trimmingCharacters(in: .whitespaces))
        }
        words.removeFirst()
        let unitWord = words.first?.lowercased().trimmingCharacters(in: .punctuationCharacters) ?? ""
        let units: [String: (String, Double)] = [
            "g": ("g", 1), "gr": ("g", 1), "gram": ("g", 1), "kg": ("g", 1000),
            "ml": ("ml", 1), "l": ("ml", 1000), "dl": ("ml", 100), "cl": ("ml", 10),
            "el": ("ml", 15), "eetlepel": ("ml", 15), "eetlepels": ("ml", 15),
            "tl": ("ml", 5), "theelepel": ("ml", 5), "theelepels": ("ml", 5),
        ]
        if let (unit, factor) = units[unitWord] {
            words.removeFirst()
            return (amount * factor, unit, words.joined(separator: " "))
        }
        return (amount, "stuk", words.joined(separator: " "))
    }

    private static func number(_ s: String) -> Double? {
        let fractions: [String: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3]
        if let f = fractions[s] { return f }
        // "1-2" of "1–2": neem het eerste getal.
        let head = s.split(whereSeparator: { $0 == "-" || $0 == "–" }).first.map(String.init) ?? s
        return Double(head.replacingOccurrences(of: ",", with: "."))
    }
}

@Model
final class Dish {
    var syncID: UUID = UUID.zero
    var name: String
    var url: String = ""
    /// Foto van de receptsite; een eigen foto (op het toestel) gaat vóór.
    var imageURL: String = ""
    /// 0 = nog geen oordeel.
    var rating: Int = 0
    var labels: [String] = []
    var ingredients: [DishIngredient] = []
    /// Bereidingsstappen, één regel per stap. Van de site overgenomen of zelf getikt —
    /// het recept staat ín de app, je hoeft de site niet meer open.
    var steps: [String] = []
    var servings: Double = 0
    var minutes: Int = 0
    /// Voedingswaarde per portie zoals de site 'm meegaf; 0 = onbekend. Startwaarde —
    /// gekoppelde producten gaan vóór zodra ze compleet zijn.
    var siteProtein: Int = 0
    var siteKcal: Int = 0
    var createdAt: Date = Date.now

    init(name: String) {
        self.syncID = UUID()
        self.name = name
    }

    struct Macros { var protein: Int; var kcal: Int; var complete: Bool }

    /// Per portie. Gekoppelde producten winnen als álle regels gekoppeld zijn; anders de
    /// waarde van de site; anders wat er gekoppeld is, gemarkeerd als onvolledig.
    func macros(products: [FoodProduct]) -> Macros? {
        let linked = ingredients.filter { $0.productID != nil }
        let byID = Dictionary(products.map { ($0.syncID, $0) }, uniquingKeysWith: { a, _ in a })
        var protein = 0.0, kcal = 0.0
        for i in linked {
            guard let p = i.productID.flatMap({ byID[$0] }) else { continue }
            let grams = i.unit == "stuk" ? i.amount * (p.servingGrams > 0 ? p.servingGrams : 100) : i.amount
            protein += p.protein100 * grams / 100
            kcal += p.kcal100 * grams / 100
        }
        let portions = max(servings, 1)
        let complete = !ingredients.isEmpty && linked.count == ingredients.count
        if complete || (siteKcal == 0 && !linked.isEmpty) {
            return Macros(protein: Int((protein / portions).rounded()), kcal: Int((kcal / portions).rounded()), complete: complete)
        }
        if siteKcal > 0 || siteProtein > 0 {
            return Macros(protein: siteProtein, kcal: siteKcal, complete: true)
        }
        return nil
    }
}

/// Eén keer dat een gerecht gemaakt wordt. Niet afgevinkt = gepland of bezig.
@Model
final class Cook {
    var syncID: UUID = UUID.zero
    var dishID: UUID
    var date: Date
    var note: String = ""
    var done: Bool = false
    var createdAt: Date = Date.now

    init(dishID: UUID, date: Date = .now) {
        self.syncID = UUID()
        self.dishID = dishID
        self.date = date
    }
}

extension Dish: SyncedRecord {
    static var syncTable: String { "dishes" }
    static func blank() -> Dish { Dish(name: "") }
}
extension Cook: SyncedRecord {
    static var syncTable: String { "dish_cooks" }
    static func blank() -> Cook { Cook(dishID: .zero) }
}

/// Eigen foto van je bord. Alleen op dit toestel, net als de progress-foto's.
enum DishPhoto {
    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("DishPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func url(_ dish: Dish) -> URL { directory.appendingPathComponent(dish.syncID.uuidString + ".jpg") }
    static func existing(_ dish: Dish) -> URL? {
        let u = url(dish)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static func save(_ data: Data, for dish: Dish) throws {
        try ProductPhoto.downscaled(data).write(to: url(dish))
    }
    static func remove(_ dish: Dish) { try? FileManager.default.removeItem(at: url(dish)) }
}

// MARK: - Recept van een link
//
// De meeste receptsites (AH, Jumbo, Leuke Recepten, Lekker en Simpel, BBC Good Food)
// sturen schema.org `Recipe` mee als ld+json. Daar halen we alles uit; is het er niet
// (24Kitchen), dan alleen de titel uit og:title en vul je de rest zelf in.

struct ImportedRecipe: Equatable {
    var name = ""
    var imageURL = ""
    var ingredients: [String] = []
    var steps: [String] = []
    var servings: Double = 0
    var minutes = 0
    var protein = 0
    var kcal = 0
    /// Categorie/keuken van de site, als voorstel voor labels.
    var labelSuggestions: [String] = []
}

enum RecipeImport {
    static func fetch(_ url: URL) async -> ImportedRecipe? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(html: html)
    }

    static func parse(html: String) -> ImportedRecipe? {
        var result = ImportedRecipe()
        for block in ldJSONBlocks(html) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(block.utf8)),
                  let recipe = findRecipe(json) else { continue }
            result.name = string(recipe["name"])
            result.imageURL = imageURL(recipe["image"])
            result.ingredients = (recipe["recipeIngredient"] as? [String] ?? [])
                .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces) }
            result.steps = steps(recipe["recipeInstructions"])
            result.servings = servings(recipe["recipeYield"])
            result.minutes = minutes(string(recipe["totalTime"]))
            if let n = recipe["nutrition"] as? [String: Any] {
                result.kcal = leadingInt(string(n["calories"]))
                result.protein = leadingInt(string(n["proteinContent"]))
            }
            result.labelSuggestions = (strings(recipe["recipeCuisine"]) + strings(recipe["recipeCategory"]))
                .map { $0.lowercased() }
            result.labelSuggestions = Array(NSOrderedSet(array: result.labelSuggestions)) as? [String] ?? []
            if !result.name.isEmpty { return result }
        }
        // Geen Recipe-data: dan alleen de titel.
        if let m = html.range(of: #"property="og:title"\s+content="([^"]*)""#, options: .regularExpression) {
            let tag = String(html[m])
            let title = tag.components(separatedBy: "content=\"").last?.dropLast() ?? ""
            result.name = decodeEntities(String(title))
        }
        if let m = html.range(of: #"property="og:image"\s+content="([^"]*)""#, options: .regularExpression) {
            let tag = String(html[m])
            result.imageURL = String(tag.components(separatedBy: "content=\"").last?.dropLast() ?? "")
        }
        return result.name.isEmpty ? nil : result
    }

    private static func ldJSONBlocks(_ html: String) -> [String] {
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Zoekt door `@graph`, arrays en geneste objecten naar het eerste `@type: Recipe`.
    private static func findRecipe(_ json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            let type = dict["@type"]
            if type as? String == "Recipe" || (type as? [String])?.contains("Recipe") == true { return dict }
            for v in dict.values { if let r = findRecipe(v) { return r } }
        } else if let arr = json as? [Any] {
            for v in arr { if let r = findRecipe(v) { return r } }
        }
        return nil
    }

    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return decodeEntities(s) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    private static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return (v as? [String]) ?? []
    }
    /// image: "url" | ["url"] | {url} | [{url}]
    private static func imageURL(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return string(d["url"]) }
        if let a = v as? [Any], let first = a.first { return imageURL(first) }
        return ""
    }
    /// recipeInstructions: "tekst" | ["stap", …] | [HowToStep{text}] | [HowToSection{itemListElement: [HowToStep]}]
    private static func steps(_ v: Any?) -> [String] {
        if let s = v as? String {
            return s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let d = v as? [String: Any] {
            if let items = d["itemListElement"] { return steps(items) }
            let text = string(d["text"])
            return text.isEmpty ? [] : [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if let a = v as? [Any] { return a.flatMap(steps) }
        return []
    }
    /// recipeYield: 4 | "4" | "4 porties" | ["4", "4 personen"]
    private static func servings(_ v: Any?) -> Double {
        if let a = v as? [Any] { return a.map(servings).first { $0 > 0 } ?? 0 }
        return Double(leadingInt(string(v)))
    }
    /// "PT1H10M" → 70. Geen ISO8601-bibliotheek voor drie letters.
    static func minutes(_ iso: String) -> Int {
        guard iso.hasPrefix("PT") else { return 0 }
        var total = 0, current = ""
        for ch in iso.dropFirst(2) {
            if ch.isNumber { current.append(ch); continue }
            let n = Int(current) ?? 0
            current = ""
            switch ch { case "H": total += n * 60; case "M": total += n; default: break }
        }
        return total
    }
    /// "620 kcal" → 620; "38 g" → 38; "38.4 g" → 38.
    private static func leadingInt(_ s: String) -> Int {
        let head = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Int(Double(head.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&eacute;", with: "é")
    }
}
