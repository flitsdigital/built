import SwiftUI
import SwiftData
import VisionKit
import AVFoundation
import PhotosUI
import UIKit

// MARK: - OpenFoodFacts (gratis, open, geen key)

/// Zoeken/opzoeken via OpenFoodFacts, robuust gemaakt: meerdere endpoints tegelijk
/// (incl. de NL-mirror), één retry bij een storing, en een cache op schijf zodat
/// eerdere resultaten instant én offline blijven werken.
enum OFF {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": "Built/1.0 (iOS)"] // OFF throttelt zonder UA
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: cfg)
    }()

    private static let fields = "code,product_name,brands,nutriments,image_front_small_url,serving_quantity,product_quantity,categories_tags"

    /// Voedingswaarden per 100 g/ml, plus optionele eigen portie/verpakking in gram.
    struct Product: Identifiable, Codable {
        var id: String { barcode.isEmpty ? name : barcode }
        var name: String
        var brand: String
        var barcode: String
        var protein100: Double
        var kcal100: Double
        var carbs100: Double
        var fat100: Double
        var imageURL: String
        var servingGrams: Double
        var packageGrams: Double
        /// Afgeleid uit `categories`: drank → ml, rest → g. Slimme gok, in de
        /// portie-sheet om te zetten.
        var unit: FoodUnit
        var categories: [String]
    }

    // MARK: - Cache op schijf (eerder gevonden = instant + offline)
    //
    // Niet te vervangen door de `URLCache` hierboven: de proxy is een POST, en die
    // bewaart URLSession niet. Deze cache zit bovendien op het geparste resultaat, dus
    // hij dekt beide paden hieronder met één ingang.

    private static let cacheURL = URL.cachesDirectory.appendingPathComponent("off_query_cache.json")
    private static var queryCache: [String: [Product]] =
        (try? JSONDecoder().decode([String: [Product]].self, from: Data(contentsOf: cacheURL))) ?? [:]
    private static func persistCache() { try? JSONEncoder().encode(queryCache).write(to: cacheURL) }

    // MARK: - Zoeken

    /// nil = OFF niet bereikbaar; [] = echt geen resultaten.
    ///
    /// Eerst onze eigen gecachete catalogus: één snelle round-trip, en OFF krijgt één
    /// request per uniek product in plaats van één per gebruiker. Valt die weg, dan
    /// rechtstreeks naar search-a-licious — in de praktijk de snelste en stabielste van
    /// OFF's endpoints.
    static func search(_ query: String) async -> [Product]? {
        let key = query.lowercased()
        if let cached = queryCache[key] { return cached } // eerder gezocht → instant, ook offline
        var result = await proxy(["search": query])
        if result == nil { result = await sal(query) }
        if let result, !result.isEmpty {
            queryCache[key] = result
            persistCache()
        }
        return result
    }

    // MARK: - Eigen proxy (gedeelde cache)

    /// Vraagt de `off-proxy` edge function. nil = niet beschikbaar (niet uitgerold, geen
    /// sessie, netwerk stuk) — dan valt de beller terug op OFF rechtstreeks, zodat het
    /// uitrollen van de function geen harde afhankelijkheid is.
    private static func proxy(_ body: [String: String]) async -> [Product]? {
        guard let data = try? JSONEncoder().encode(body),
              let request = await Sync.functionRequest("off-proxy", body: data),
              let (payload, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: payload)
        else { return nil }
        return decoded.products.items.compactMap(product(from:))
    }

    private struct ProxyResponse: Decodable { var products: Lenient<RawProduct> }

    /// search-a-licious: eigen backend, los van de cgi-servers — en in de praktijk de
    /// snelste en stabielste van de drie.
    ///
    /// Geen `sort_by`: op `-popularity_key` sorteren overstemt de tekstmatch volledig
    /// ("Volle melk" gaf dan Geröstete Mandel en Skyr Nature). De standaard-sortering
    /// is relevantie, en die geeft wél de juiste producten.
    private static func sal(_ query: String) async -> [Product]? {
        var c = URLComponents(string: "https://search.openfoodfacts.org/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "langs", value: "nl,en"),
                        .init(name: "page_size", value: "20"),
                        .init(name: "fields", value: fields)]
        guard let url = c.url, let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(SaLResponse.self, from: data) else { return nil }
        return r.hits.items.compactMap(product(from:))
    }

    // MARK: - Barcode (met retry)

    static func lookup(barcode: String) async -> Product? {
        // Barcodes zijn de beste cache-kandidaten: één product, nooit een tikfout, en het
        // scannen van dezelfde reep door duizend mensen hoort één OFF-request te zijn.
        if let hit = await proxy(["barcode": barcode]) { return hit.first }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)"),
                  let (data, resp) = try? await session.data(from: url) else { continue }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return nil } // bestaat niet → niet retryen
            if code == 200, let r = try? JSONDecoder().decode(LookupResponse.self, from: data), let raw = r.product {
                return product(from: raw)
            }
        }
        return nil
    }

    // MARK: - Response-parsing

    private struct LookupResponse: Decodable { var product: RawProduct? }
    private struct SaLResponse: Decodable { var hits: Lenient<RawProduct> }
    private struct RawProduct: Decodable {
        var code: String?
        var product_name: String?
        var brands: FlexibleString?
        var image_front_small_url: String?
        var serving_quantity: FlexibleDouble?
        var product_quantity: FlexibleDouble?
        var nutriments: Nutriments?
        var categories_tags: [String]?
    }

    /// OFF levert hoeveelheden soms als getal, soms als string ("250").
    struct FlexibleDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            value = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
        }
    }

    /// `brands` is een string ("Alpro") op de cgi-endpoints, maar een array (["Alpro"])
    /// op search-a-licious. Met `String?` klapte die hele response eruit, waardoor de
    /// snelste en stabielste van de drie backends in de praktijk nooit werd gebruikt.
    struct FlexibleString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let a = try? c.decode([String].self) { value = a.joined(separator: ", ") }
            else { value = "" }
        }
    }

    /// Slaat losse producten over die OFF in een onverwacht formaat teruggeeft, i.p.v.
    /// de hele lijst te laten falen op één rotte appel.
    struct Lenient<T: Decodable>: Decodable {
        let items: [T]
        /// Leest niets en slaagt dus altijd — gebruikt om een onleesbaar element over
        /// te slaan, want een mislukte `decode` schuift de index niet op.
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var out: [T] = []
            while !c.isAtEnd {
                if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
            }
            items = out
        }
    }

    private struct Nutriments: Decodable {
        var proteins: Double?
        var kcal: Double?
        var carbs: Double?
        var fat: Double?
        enum CodingKeys: String, CodingKey {
            case proteins = "proteins_100g"
            case kcal = "energy-kcal_100g"
            case carbs = "carbohydrates_100g"
            case fat = "fat_100g"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            proteins = Self.number(c, .proteins)
            kcal = Self.number(c, .kcal)
            carbs = Self.number(c, .carbs)
            fat = Self.number(c, .fat)
        }
        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Double? {
            (try? c.decode(Double.self, forKey: k)) ?? (try? c.decode(String.self, forKey: k)).flatMap(Double.init)
        }
    }

    private static func product(from raw: RawProduct) -> Product? {
        guard let name = raw.product_name, !name.isEmpty, let n = raw.nutriments,
              n.proteins != nil || n.kcal != nil else { return nil }
        func sane(_ v: Double?, _ upper: Double) -> Double {
            guard let v, v >= 1, v <= upper else { return 0 }
            return v
        }
        let categories = raw.categories_tags ?? []
        return Product(name: name, brand: raw.brands?.value ?? "", barcode: raw.code ?? "",
                       protein100: n.proteins ?? 0, kcal100: n.kcal ?? 0,
                       carbs100: n.carbs ?? 0, fat100: n.fat ?? 0,
                       imageURL: raw.image_front_small_url ?? "",
                       servingGrams: sane(raw.serving_quantity?.value, 1500),
                       packageGrams: sane(raw.product_quantity?.value, 5000),
                       unit: FoodUnit.detect(categories: categories, name: name),
                       categories: categories)
    }
}

/// Eigen foto bij een product: een bestand in de app-container, net als de progress
/// foto's. Bewust niet in de sync — die is één JSON-transactie en daar horen geen bytes
/// in; een mislukte upload zou een rij kunnen blokkeren, en dat mag nooit.
///
/// De bestandsnaam komt uit barcode-of-naam, precies de sleutel waarop de app een product
/// al herkent (`logFood`), via `UUID.stable(from:)` — zodat hij niet van een UUID afhangt
/// die de foto niet kent.
enum ProductPhoto {
    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("ProductPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(barcode: String, name: String) -> URL {
        let key = barcode.isEmpty ? name : barcode
        return directory.appendingPathComponent(UUID.stable(from: key).uuidString + ".jpg")
    }

    /// Nil als er geen eigen foto is — dat is ook het antwoord op "heeft dit product er een?".
    static func existing(barcode: String, name: String) -> URL? {
        let url = url(barcode: barcode, name: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func save(_ data: Data, barcode: String, name: String) throws {
        try downscaled(data).write(to: url(barcode: barcode, name: name))
    }

    static func remove(barcode: String, name: String) {
        try? FileManager.default.removeItem(at: url(barcode: barcode, name: name))
    }

    /// Een rauwe 12MP-foto per product vult de container zonder dat je het ziet, en 1000 px
    /// is ruim genoeg voor een thumb van 120 pt en de volledige weergave.
    private static func downscaled(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let side = max(image.size.width, image.size.height)
        guard side > 1000 else { return image.jpegData(compressionQuality: 0.8) ?? data }
        let factor = 1000 / side
        let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        return image.preparingThumbnail(of: target)?.jpegData(compressionQuality: 0.8) ?? data
    }
}

extension FoodProduct {
    var localPhoto: URL? { ProductPhoto.existing(barcode: barcode, name: name) }
}

/// Productfoto met vork-fallback; AsyncImage cachet via URLCache.
struct FoodThumb: View {
    var url: String
    var size: CGFloat = 40
    /// Eigen foto gaat vóór die van OpenFoodFacts: die heb je zelf uitgekozen.
    var photo: URL?

    var body: some View {
        Group {
            if let photo, let ui = UIImage(contentsOfFile: photo.path) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                AsyncImage(url: URL(string: url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "fork.knife")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true) // staat altijd naast de productnaam
    }
}

// MARK: - Eten-tab

struct FoodView: View {
    let profile: Profile
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
    @Environment(\.modelContext) private var context
    @Query private var proteins: [ProteinEntry]
    @Query private var products: [FoodProduct]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \Meal.createdAt) private var meals: [Meal]

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var logMeal: String?
    @State private var editingEntry: ProteinEntry?
    @State private var showReport = false

    private var cal: Calendar { .current }
    private var isToday: Bool { cal.isDateInToday(day) }
    private var dayEntries: [ProteinEntry] {
        proteins.filter { dayKey($0.date) == dayKey(day) }.sorted { $0.date < $1.date }
    }
    private var totalProtein: Int { dayEntries.map(\.grams).reduce(0, +) }
    private var totalKcal: Int { dayEntries.map(\.kcal).reduce(0, +) }
    private var totalCarbs: Int { dayEntries.map(\.carbs).reduce(0, +) }
    private var totalFat: Int { dayEntries.map(\.fat).reduce(0, +) }
    private var kcalTarget: Int {
        // Zelfde "huidig gewicht" als het dashboard: 7-daags gemiddelde, niet één ruisige weging.
        profile.kcalTargetEffective(currentWeight: weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? profile.startWeight)
    }

    private func entries(for meal: String) -> [ProteinEntry] {
        dayEntries.filter { $0.mealKey == meal }
    }

    // MARK: - Dag overnemen
    //
    // Je eet grotendeels hetzelfde. Dit was al gebouwd (`repeatYesterday`) maar hing aan
    // een sheet die nooit werd getoond; nu staat het gewoon in het ⋯-menu.

    private var previousDay: Date { cal.date(byAdding: .day, value: -1, to: day) ?? day }
    private var previousDayLabel: String {
        cal.isDateInToday(day) ? "gisteren" : previousDay.formatted(.dateTime.weekday(.wide))
    }
    private var previousDayEntries: [ProteinEntry] {
        let key = dayKey(previousDay)
        return proteins.filter { dayKey($0.date) == key }
    }

    /// Kopieert de vorige dag naar de geselecteerde dag, met behoud van portie en eenheid.
    private func copyPreviousDay() {
        for e in previousDayEntries {
            // Zelfde klokttijd, andere dag — en nooit in de toekomst.
            let comps = cal.dateComponents([.hour, .minute], from: e.date)
            let stamp = min(cal.date(bySettingHour: comps.hour ?? 12, minute: comps.minute ?? 0,
                                     second: 0, of: day) ?? day, .now)
            context.insert(ProteinEntry(date: stamp, grams: e.grams, label: e.label, kcal: e.kcal,
                                        carbs: e.carbs, fat: e.fat, meal: e.mealKey,
                                        amount: e.amount, unit: e.foodUnit))
        }
    }

    private var coachLine: String? {
        guard isToday else { return nil }
        let remaining = profile.proteinTarget - totalProtein
        if remaining <= 0 { return "Eiwitdoel binnen 🎯 Nog \(max(kcalTarget - totalKcal, 0)) kcal ruimte." }
        if let suggestion = meals.filter({ $0.proteinPerServing > 0 }).sorted(by: { $0.proteinPerServing > $1.proteinPerServing })
            .first(where: { $0.proteinPerServing <= remaining + 15 }) {
            return "Nog \(remaining) g te gaan — \(suggestion.name) (\(suggestion.proteinPerServing) g) brengt je op \(totalProtein + suggestion.proteinPerServing) g."
        }
        return "Nog \(remaining) g eiwit te gaan."
    }

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    @ViewBuilder private var content: some View {
        List {
            Section {
                dayHeader
                summaryRow
            }
            .listRowSeparator(.hidden)

            ForEach(mealSlots, id: \.self) { meal in
                mealSection(meal)
            }

            if let coachLine {
                Section {
                    Label(coachLine, systemImage: "lightbulb.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listSectionSpacing(14)
        .navigationTitle("Eten")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Weekrapport", systemImage: "chart.bar.doc.horizontal") { showReport = true }
                    if !previousDayEntries.isEmpty {
                        Divider()
                        Button("Neem \(previousDayLabel) over (\(previousDayEntries.map(\.grams).reduce(0, +)) g)",
                               systemImage: "arrow.uturn.backward") { copyPreviousDay() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Meer")
            }
        }
        .sheet(isPresented: $showReport) {
            NutritionReportSheet(profile: profile, kcalTarget: kcalTarget)
        }
        .sheet(item: $logMeal) { meal in
            FoodLogSheet(profile: profile, meal: meal, day: day)
        }
        .sheet(item: $editingEntry) { entry in
            ProteinEntrySheet(entry: entry)
        }
        .sensoryFeedback(.increase, trigger: totalProtein) { old, new in new > old }
    }

    private var dayHeader: some View {
        HStack {
            dayChevron("chevron.left", enabled: true) {
                day = cal.date(byAdding: .day, value: -1, to: day)!
            }
            Spacer()
            VStack(spacing: 1) {
                Text(isToday ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                if !isToday {
                    Button("Naar vandaag") {
                        withAnimation(.snappy(duration: 0.2)) { day = cal.startOfDay(for: .now) }
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            dayChevron("chevron.right", enabled: !isToday) {
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
        }
    }

    private func dayChevron(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.footnote.bold())
                .foregroundStyle(enabled ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon.contains("left") ? "Vorige dag" : "Volgende dag")
    }

    private var summaryRow: some View {
        VStack(spacing: 12) {
            MacroRings(protein: totalProtein, proteinTarget: profile.proteinTarget,
                       carbs: totalCarbs, fat: totalFat)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(totalKcal)")
                        .font(.subheadline.bold().monospacedDigit())
                    Text("/ \(kcalTarget) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(kcalTarget - totalKcal >= 0 ? "\(kcalTarget - totalKcal) over" : "\(totalKcal - kcalTarget) te veel")
                        .font(.caption)
                        .foregroundStyle(totalKcal > kcalTarget ? .orange : .secondary)
                }
                ProgressView(value: min(Double(totalKcal) / Double(max(kcalTarget, 1)), 1))
                    .tint(totalKcal > kcalTarget ? .orange : .green)
            }
        }
        .padding(.vertical, 8)
    }

    private static let mealEmoji = ["breakfast": "🍳", "lunch": "🥪", "dinner": "🍽️", "snack": "🍎"]

    private func mealSection(_ meal: String) -> some View {
        let list = entries(for: meal)
        let protein = list.map(\.grams).reduce(0, +)
        let kcal = list.map(\.kcal).reduce(0, +)
        return Section {
            // Kaartkop: hele rij tikbaar om te loggen (Yazio-patroon)
            Button {
                logMeal = meal
            } label: {
                HStack(spacing: 12) {
                    Text(Self.mealEmoji[meal] ?? "🍽️")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mealSlotNames[meal] ?? meal)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(list.isEmpty ? "Nog niets gelogd" : "\(protein) g eiwit · \(kcal) kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(list) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    HStack(spacing: 10) {
                        let product = products.first { $0.name == entry.label }
                        FoodThumb(url: product?.imageURL ?? "", size: 34, photo: product?.localPhoto)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if entry.kcal > 0 {
                                Text("\(entry.kcal) kcal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(entry.grams) g")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for i in offsets { context.deleteSynced(list[i]) }
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Log-sheet: Scan / Zoeken / Snel / Recepten

struct FoodLogSheet: View {
    let profile: Profile
    var meal: String
    var day: Date
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodProduct.lastUsed, order: .reverse) private var products: [FoodProduct]
    @Query(sort: \Meal.createdAt) private var recipes: [Meal]

    @State private var mode = 0
    @State private var query = ""
    @State private var results: [OFF.Product] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var retryToken = 0
    @State private var pending: PendingFood?   // alleen nog voor een onbekende barcode
    /// Product waarvan de pagina openstaat. nil = terug in de lijst.
    @State private var detail: PendingFood?
    /// Zojuist gescand product; krijgt dezelfde portie-editor als een zoekrij.
    @State private var scanned: PendingFood?
    @State private var portionAmount = 100
    @State private var portionUnit: FoodUnit = .gram
    @State private var scanError: String?
    @State private var manualBarcode = ""
    @State private var cameraDenied = false
    @State private var lookingUp = false
    // Eigen item (per 100 g/ml, net als elk ander product)
    @State private var quickLabel = ""
    @State private var quickProtein: Double?
    @State private var quickKcal: Double?
    @State private var quickCarbs: Double?
    @State private var quickFat: Double?
    /// Labels van wat je in deze sessie hebt gelogd — voedt de balk onderin.
    @State private var added: [String] = []
    @Query private var todaysEntries: [ProteinEntry]

    struct PendingFood: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var brand = ""
        var barcode = ""
        var protein100: Double
        var kcal100: Double
        var carbs100: Double = 0
        var fat100: Double = 0
        var imageURL = ""
        var servingGrams: Double = 0
        var servingName = ""
        var packageGrams: Double = 0
        var editable = false
        var unit: FoodUnit = .gram
        var categories: [String] = []

        var localPhoto: URL? { ProductPhoto.existing(barcode: barcode, name: name) }

        /// Uit je eigen opgeslagen producten.
        init(_ p: FoodProduct) {
            name = p.name; brand = p.brand; barcode = p.barcode
            protein100 = p.protein100; kcal100 = p.kcal100
            carbs100 = p.carbs100; fat100 = p.fat100
            imageURL = p.imageURL
            servingGrams = p.servingGrams; servingName = p.servingName
            unit = p.foodUnit; categories = p.categoryList
        }

        /// Uit een zoekresultaat of scan. Geen `servingName`: die kent OFF niet, maar
        /// `packageGrams` wél — daar komt de "Heel pak"-portie vandaan.
        init(_ p: OFF.Product) {
            name = p.name; brand = p.brand; barcode = p.barcode
            protein100 = p.protein100; kcal100 = p.kcal100
            carbs100 = p.carbs100; fat100 = p.fat100
            imageURL = p.imageURL
            servingGrams = p.servingGrams; packageGrams = p.packageGrams
            unit = p.unit; categories = p.categories
        }

        /// Handmatig ingevuld: een eigen item of een onbekende barcode.
        init(name: String, barcode: String = "", protein100: Double, kcal100: Double,
             carbs100: Double = 0, fat100: Double = 0, editable: Bool = false) {
            self.name = name; self.barcode = barcode
            self.protein100 = protein100; self.kcal100 = kcal100
            self.carbs100 = carbs100; self.fat100 = fat100
            self.editable = editable
        }
    }

    private var entryDate: Date {
        let cal = Calendar.current
        return cal.isDateInToday(day) ? .now : cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Modus", selection: $mode) {
                    Text("Zoeken").tag(0)
                    Text("Scan").tag(1)
                    Text("Eigen").tag(2)
                    Text("Recepten").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch mode {
                case 1: scanTab
                case 2: quickTab
                case 3: recipesTab
                default: searchTab
                }
            }
            .navigationTitle("Loggen — \(mealSlotNames[meal] ?? meal)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { dismiss() }
                }
            }
            // Meerdere items achter elkaar loggen: de sheet blijft open en houdt bij
            // wat je hebt toegevoegd. Eén ontbijt van vier dingen was vier keer de
            // hele flow doorlopen.
            .safeAreaInset(edge: .bottom) {
                if !added.isEmpty { addedTray }
            }
            .sheet(item: $pending) { food in
                FoodPortionSheet(food: food, meal: meal, entryDate: entryDate) { label in
                    withAnimation(.snappy(duration: 0.25)) { added.append(label) }
                }
            }
            .navigationDestination(item: $detail) { food in
                FoodDetailView(food: food, lastAmount: lastAmount(for: food)) { amount, unit in
                    logFood(food, amount: amount, unit: unit)
                    detail = nil
                }
            }
        }
    }

    /// Wat je zojuist toevoegde, met een ongedaan-maken en een afsluitknop.
    private var addedTray: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(added.count) toegevoegd")
                    .font(.subheadline.bold())
                Text(added.suffix(2).reversed().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Ongedaan") { undoLast() }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Klaar") { dismiss() }
                .font(.subheadline.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Verwijdert het laatst gelogde item van deze dag+maaltijd weer.
    private func undoLast() {
        guard !added.isEmpty else { return }
        let key = dayKey(entryDate)
        let mine = todaysEntries.filter { dayKey($0.date) == key && $0.mealKey == meal }
        if let last = mine.max(by: { $0.date < $1.date }) { context.deleteSynced(last) }
        withAnimation(.snappy(duration: 0.25)) { _ = added.popLast() }
    }

    // MARK: Zoeken

    /// Wat je normaal gesproken rónd dit tijdstip eet. `suggestions()` weegt items die
    /// je vaak op dit uur logt zwaarder — die functie bestond al maar werd nergens
    /// gebruikt (hij hing aan een sheet die nooit werd getoond).
    private var timeSuggestions: [(key: String, label: String, grams: Int, kcal: Int)] {
        guard query.isEmpty else { return [] }
        let known = Set(ownMatches.map(\.name))
        return todaysEntries.suggestions(limit: 6).filter { !known.contains($0.label) }
    }

    private var searchTab: some View {
        List {
            Section {
                TextField("Zoek product (bijv. kwark)", text: $query)
                    .autocorrectionDisabled()
            }
            let suggestions = timeSuggestions
            if !suggestions.isEmpty {
                Section("Vaak rond dit tijdstip") {
                    ForEach(suggestions, id: \.key) { s in
                        Button {
                            context.insert(ProteinEntry(date: entryDate, grams: s.grams, label: s.label,
                                                        kcal: s.kcal, meal: meal))
                            withAnimation(.snappy(duration: 0.25)) { added.append(s.label) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                                    .frame(width: 34, height: 34)
                                    .background(.builtTint(.green), in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
                                    .accessibilityHidden(true)
                                Text(s.label).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text("\(s.grams) g\(s.kcal > 0 ? " · \(s.kcal) kcal" : "")")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let own = ownMatches
            if !own.isEmpty {
                Section("Jouw producten") {
                    ForEach(own) { product in
                        let food = PendingFood(product)
                        detailRow(food, favorite: product.favorite, lastAmount: product.lastAmount)
                            .swipeActions(edge: .leading) {
                                Button {
                                    product.favorite.toggle()
                                } label: {
                                    Label(product.favorite ? "Niet favoriet" : "Favoriet",
                                          systemImage: product.favorite ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                            }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            // Tombstones gaan over rijen; het bestand moet er zelf mee.
                            ProductPhoto.remove(barcode: own[i].barcode, name: own[i].name)
                            context.deleteSynced(own[i])
                        }
                    }
                }
            }
            if query.count >= 3 {
                Section("OpenFoodFacts") {
                    if searching {
                        HStack { ProgressView(); Text("Zoeken…").foregroundStyle(.secondary) }
                    } else if searchFailed {
                        Label("OpenFoodFacts is even niet bereikbaar.", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("Opnieuw proberen") { retryToken += 1 }
                    } else if results.isEmpty {
                        Text("Niets gevonden. Probeer de scanner of voeg zelf toe via Eigen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { product in
                        let food = PendingFood(product)
                        detailRow(food, favorite: false, lastAmount: lastAmount(for: food))
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: "\(query)#\(retryToken)") {
            let q = query
            guard q.count >= 3 else { results = []; searching = false; searchFailed = false; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(400)) // debounce
            guard !Task.isCancelled else { return }
            let found = await OFF.search(q)
            // Geannuleerde oudere zoektaak mag nieuwere resultaten niet overschrijven
            guard !Task.isCancelled, q == query else { return }
            results = found ?? []
            searchFailed = found == nil
            searching = false
        }
    }

    private var ownMatches: [FoodProduct] {
        let base = query.isEmpty
            ? products
            : products.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.brand.localizedCaseInsensitiveContains(query) }
        return Array(base.sorted { ($0.favorite ? 0 : 1, $1.lastUsed) < (($1.favorite ? 0 : 1), $0.lastUsed) }.prefix(10))
    }

    /// Rij die doorklikt naar de productpagina. De portie-editor klapte hier vroeger
    /// direct onder de rij open — sneller, maar je logde voordat je de macro's had
    /// gezien, en het merk en de voedingswaarde stonden nergens.
    private func detailRow(_ food: PendingFood, favorite: Bool, lastAmount: Double) -> some View {
        Button {
            detail = food
        } label: {
            HStack(spacing: 10) {
                productRow(food, favorite: favorite, lastAmount: lastAmount)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // Zonder dit vangt alleen de tekst de tik: de ruimte tussen naam en chevron
            // is een Spacer, en die is voor een plain button geen doelwit.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Wat je vorige keer van dit product nam. Op barcode, en anders op naam — een
    /// eigen product heeft er geen.
    private func lastAmount(for food: PendingFood) -> Double {
        products.first {
            (!food.barcode.isEmpty && $0.barcode == food.barcode)
                || (food.barcode.isEmpty && $0.name == food.name)
        }?.lastAmount ?? 0
    }

    /// Bewaart/werkt het product bij en logt de portie. Gedeeld door de uitklaprij en
    /// de scanner, zodat "wat er precies wordt opgeslagen" op één plek staat.
    private func logFood(_ food: PendingFood, amount: Int, unit: FoodUnit) {
        let product: FoodProduct
        if let existing = products.first(where: { (!food.barcode.isEmpty && $0.barcode == food.barcode)
                || (food.barcode.isEmpty && $0.name == food.name) }) {
            product = existing
        } else {
            product = FoodProduct(name: food.name, brand: food.brand, barcode: food.barcode,
                                  protein100: food.protein100, kcal100: food.kcal100,
                                  carbs100: food.carbs100, fat100: food.fat100)
            product.imageURL = food.imageURL
            context.insert(product)
        }
        if food.servingGrams > 0 {
            product.servingGrams = food.servingGrams
            product.servingName = food.servingName
        }
        product.lastUsed = .now
        product.unit = unit.rawValue
        product.lastAmount = Double(amount) // volgende keer meteen de juiste portie
        if !food.categories.isEmpty { product.categories = food.categories.joined(separator: ",") }

        func scaled(_ per100: Double) -> Int { Int((per100 * Double(amount) / 100).rounded()) }
        context.insert(ProteinEntry(date: entryDate, grams: scaled(food.protein100), label: food.name,
                                    kcal: scaled(food.kcal100), carbs: scaled(food.carbs100),
                                    fat: scaled(food.fat100), meal: meal,
                                    amount: Double(amount), unit: unit))
        withAnimation(.snappy(duration: 0.25)) { added.append(food.name) }
    }

    /// De rij toont wat jíj normaal neemt, al doorgerekend — niet per 100 g. Zo is de rij
    /// zelf de beslissing in plaats van een som die je nog moet maken. Volgorde: laatste
    /// portie → portiegrootte van het pak → 100 g.
    private func productRow(_ food: PendingFood, favorite: Bool, lastAmount: Double) -> some View {
        let amount = lastAmount > 0 ? lastAmount : (food.servingGrams > 0 ? food.servingGrams : 100)
        let factor = amount / 100
        let kcal = Int((food.kcal100 * factor).rounded())
        let protein = Int((food.protein100 * factor).rounded())
        return HStack(spacing: 10) {
            FoodThumb(url: food.imageURL, photo: food.localPhoto)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(food.name).foregroundStyle(.primary).lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Favoriet")
                    }
                    if !food.brand.isEmpty {
                        Text(food.brand).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                // Waarde links onder de naam i.p.v. rechts uitgelijnd: één kolom om langs
                // te scannen in plaats van heen-en-weer per rij.
                HStack(spacing: 4) {
                    Text("\(kcal) kcal").foregroundStyle(.green)
                    Text("· \(protein) g eiwit · \(amount.kgText) \(food.unit.label)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
    }

    // MARK: Scan

    private var scanTab: some View {
        List {
            Section {
                if !DataScannerViewController.isSupported {
                    // Ook waar op een iPhone ouder dan de XS — vandaar geen "(simulator)",
                    // dat gaf op zo'n toestel een misleidende verklaring.
                    Label("Scannen wordt op dit toestel niet ondersteund. Voer de barcode hieronder in.",
                          systemImage: "camera.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if cameraDenied {
                    // Zonder deze tak zag je alleen een zwart vlak: isSupported is true
                    // (hardware kán het), maar zonder toestemming start de scanner niet.
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Geen toegang tot de camera", systemImage: "camera.fill")
                            .font(.subheadline.bold())
                        Text("Built mag de camera niet gebruiken, dus scannen lukt niet. Zet 'm aan in Instellingen, of voer de barcode hieronder in.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open Instellingen") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    .padding(.vertical, 4)
                } else {
                    BarcodeScanner(onScan: { handleBarcode($0) },
                                   onFailure: { scanError = $0 })
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                }
            } footer: {
                Text("Richt op de streepjescode van het product. Gevonden via OpenFoodFacts.")
            }
            if let scanned {
                Section("Gevonden") {
                    productRow(scanned, favorite: false, lastAmount: lastAmount(for: scanned))
                    PortionEditor(food: scanned, lastAmount: lastAmount(for: scanned),
                                  amount: $portionAmount, unit: $portionUnit) { amount, unit in
                        logFood(scanned, amount: amount, unit: unit)
                        self.scanned = nil
                        manualBarcode = ""
                    }
                    .id(scanned.barcode)
                }
            }
            Section {
                HStack {
                    TextField("Barcode (EAN)", text: $manualBarcode)
                        .keyboardType(.numberPad)
                    Button("Zoek") { handleBarcode(manualBarcode) }
                        .disabled(manualBarcode.count < 8 || lookingUp)
                }
                if lookingUp {
                    HStack { ProgressView(); Text("Opzoeken…").foregroundStyle(.secondary) }
                }
                if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        // De app vroeg nergens om cameratoestemming; zonder dit blijft de status
        // .notDetermined en start de scanner nooit.
        .task {
            guard DataScannerViewController.isSupported else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                cameraDenied = false
            case .notDetermined:
                cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
            default:
                cameraDenied = true
            }
        }
    }

    private func handleBarcode(_ code: String) {
        guard !lookingUp, pending == nil, scanned == nil else { return }
        scanError = nil
        // Eigen producten winnen: eerder gescand = direct raak, ook offline
        if let known = products.first(where: { $0.barcode == code }) {
            scanned = PendingFood(known)
            return
        }
        lookingUp = true
        Task {
            let found = await OFF.lookup(barcode: code)
            lookingUp = false
            if let found {
                scanned = PendingFood(found)
            } else {
                // Niet in de database → één keer zelf invullen, blijft aan de barcode hangen
                pending = PendingFood(name: "", barcode: code, protein100: 0, kcal100: 0, editable: true)
            }
        }
    }

    // MARK: Eigen item
    //
    // Zelfde vorm als elk ander product: waardes per 100 g/ml, portie kies je daarna.
    // Zo kun je 50 g van je eigen item loggen in plaats van één vaste "maaltijd", en
    // staat het item de volgende keer gewoon bij Jouw producten.

    private var quickFood: PendingFood {
        PendingFood(name: quickLabel.trimmingCharacters(in: .whitespaces),
                    protein100: quickProtein ?? 0, kcal100: quickKcal ?? 0,
                    carbs100: quickCarbs ?? 0, fat100: quickFat ?? 0)
    }

    private var quickTab: some View {
        List {
            Section {
                TextField("Naam (bijv. kipfilet)", text: $quickLabel)
                macroField("Eiwit", $quickProtein, "30")
                macroField("Kcal", $quickKcal, "250")
                macroField("Koolhydraten", $quickCarbs, "0")
                macroField("Vet", $quickFat, "0")
            } footer: {
                Text("Per 100 g/ml, net als op de verpakking. Hieronder kies je hoeveel je ervan hebt gegeten.")
            }
            if !quickFood.name.isEmpty, quickFood.protein100 + quickFood.kcal100 > 0 {
                Section("Portie") {
                    PortionEditor(food: quickFood, lastAmount: 0,
                                  amount: $portionAmount, unit: $portionUnit) { amount, unit in
                        logFood(quickFood, amount: amount, unit: unit)
                        quickLabel = ""; quickProtein = nil; quickKcal = nil; quickCarbs = nil; quickFat = nil
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func macroField(_ label: String, _ value: Binding<Double?>, _ placeholder: String) -> some View {
        LabeledContent(label) {
            TextField(placeholder, value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
        }
    }

    // MARK: Recepten

    private var recipesTab: some View {
        List {
            Section {
                ForEach(recipes.filter { $0.proteinPerServing > 0 }) { recipe in
                    Button {
                        context.insert(ProteinEntry(date: entryDate, grams: recipe.proteinPerServing,
                                                    label: recipe.name, kcal: recipe.kcalPerServing, meal: meal))
                        withAnimation(.snappy(duration: 0.25)) { added.append(recipe.name) }
                    } label: {
                        HStack {
                            Text(recipe.name).foregroundStyle(.primary)
                            if recipe.favorite {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                    .accessibilityLabel("Favoriet")
                            }
                            Spacer()
                            Text("\(recipe.proteinPerServing) g · \(recipe.kcalPerServing) kcal")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Tik om 1 portie te loggen")
            }
            Section {
                NavigationLink {
                    MealsView()
                } label: {
                    Label("Recepten beheren", systemImage: "fork.knife")
                }
            }
        }
    }
}

// MARK: - Portie kiezen, inline

/// Hoeveelheid + porties + logknop, zonder eigen sheet: klapt uit ónder de rij die je
/// aantikt. Eerder was dit een tweede sheet bovenop de eerste, waardoor je naar drie
/// lagen tegelijk keek terwijl je je keuze al had gemaakt.
///
/// Alles wat geen logactie is (favoriet, eigen portie) zit nu op de rij zelf, en de
/// maaltijd staat al in de titel van de sheet — dat scheelt drie rijen chrome.
struct PortionEditor: View {
    let food: FoodLogSheet.PendingFood
    /// Wat je vorige keer nam; 0 = onbekend.
    let lastAmount: Double
    /// Van buitenaf, want de productpagina rekent dezelfde hoeveelheid door in de
    /// macro-tegels erboven. Die moeten meelopen terwijl je aan het getal draait.
    @Binding var amount: Int
    @Binding var unit: FoodUnit
    var onLog: (Int, FoodUnit) -> Void

    private var step: Int { unit == .milliliter ? 50 : 10 }
    private func scaled(_ per100: Double) -> Int { Int((per100 * Double(amount) / 100).rounded()) }

    private var portions: [FoodPortion] {
        var out = FoodPortions.suggested(unit: unit, categories: food.categories, name: food.name)
        if food.servingGrams > 0 {
            let name = food.servingName.isEmpty ? "1 portie" : "1 \(food.servingName)"
            out.insert(FoodPortion(label: name, amount: food.servingGrams), at: 0)
        }
        if food.packageGrams > 0 {
            out.append(FoodPortion(label: "Heel pak", amount: food.packageGrams))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                stepButton("minus") { amount = max(amount - step, 0) }
                    .disabled(amount <= 0)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("100", value: $amount, format: .number)
                        .keyboardType(.numberPad)
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                        // Zonder label leest VoiceOver de placeholder, dus het veld heette "100".
                        .accessibilityLabel("Hoeveelheid")
                        .accessibilityValue("\(amount) \(unit.label)")
                    Picker("Eenheid", selection: $unit) {
                        ForEach(FoodUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.secondary)
                }
                .frame(minWidth: 110)
                stepButton("plus") { amount += step }
            }
            .frame(maxWidth: .infinity)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(portions) { p in
                        let on = amount == Int(p.amount.rounded())
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { amount = Int(p.amount.rounded()) }
                        } label: {
                            VStack(spacing: 1) {
                                Text(p.label).font(.footnote.bold())
                                Text("\(Int(p.amount)) \(unit.label)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(on ? .builtTint(.green) : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 24) // ruimte voor de fade
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.92),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }

            Button {
                onLog(amount, unit)
            } label: {
                VStack(spacing: 1) {
                    Text("Log \(scaled(food.protein100)) g eiwit · \(scaled(food.kcal100)) kcal")
                        .font(.subheadline.bold())
                    if food.carbs100 > 0 || food.fat100 > 0 {
                        Text("\(scaled(food.carbs100)) g koolhydraten · \(scaled(food.fat100)) g vet")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .disabled(amount <= 0)
        }
        .padding(.top, 4)
        .onAppear {
            unit = food.unit
            if lastAmount > 0 { amount = Int(lastAmount) }
            else if food.servingGrams > 0 { amount = Int(food.servingGrams) }
            else if unit == .milliliter { amount = 250 } // een glas
        }
    }

    /// Klein, rustig rondje. Bewust niet `.bordered`: dat rendert als een brede pil
    /// die het getal ernaast wegdrukt.
    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "minus" ? "Minder" : "Meer")
        .accessibilityValue("\(amount) \(unit.label)")
    }
}

// MARK: - Productpagina

/// Wat het is → hoeveel je nam → toevoegen. De macro's boven de portie-editor rekenen
/// mee terwijl je aan het getal draait, zodat de hoeveelheid een keuze is en geen som.
struct FoodDetailView: View {
    let food: FoodLogSheet.PendingFood
    let lastAmount: Double
    var onLog: (Int, FoodUnit) -> Void

    @State private var amount = 100
    @State private var unit: FoodUnit = .gram
    @State private var showPhoto = false
    /// Eigen foto in state, niet berekend: dan werkt het scherm meteen bij na kiezen of wissen.
    @State private var photo: URL?
    @State private var pickerItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var photoError: String?

    private func scaled(_ per100: Double) -> Int { Int((per100 * Double(amount) / 100).rounded()) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Button { showPhoto = true } label: {
                        FoodThumb(url: food.imageURL, size: 120, photo: photo)
                    }
                    .buttonStyle(.plain)
                    // zonder foto valt er niets te vergroten
                    .disabled(photo == nil && food.imageURL.isEmpty)
                    .accessibilityLabel("Foto van \(food.name)")
                    .accessibilityHint("Vergroot de foto")
                    photoActions
                    VStack(spacing: 2) {
                        Text(food.name)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        if !food.brand.isEmpty {
                            Text(food.brand).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        macroTile("Calorieën", scaled(food.kcal100), "kcal", .green)
                        macroTile("Koolh.", scaled(food.carbs100), "g", .macroCarbs)
                        macroTile("Eiwit", scaled(food.protein100), "g", .macroProtein)
                        macroTile("Vet", scaled(food.fat100), "g", .macroFat)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
            Section("Hoeveel heb je gehad?") {
                PortionEditor(food: food, lastAmount: lastAmount,
                              amount: $amount, unit: $unit, onLog: onLog)
            }
            Section("Per 100 \(food.unit.label)") {
                per100Row("Calorieën", food.kcal100, "kcal")
                per100Row("Koolhydraten", food.carbs100, "g")
                per100Row("Eiwitten", food.protein100, "g")
                per100Row("Vetten", food.fat100, "g")
            }
        }
        .navigationTitle(food.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPhoto) { photoPreview }
        .task { photo = food.localPhoto }
        .photosPicker(isPresented: $choosingPhoto, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in savePhoto(data) }
        }
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                if let data = try? await pickerItem.loadTransferable(type: Data.self) {
                    savePhoto(data)
                } else {
                    photoError = "Die foto kon niet gelezen worden."
                }
                self.pickerItem = nil
            }
        }
    }

    /// Zelf een foto bij een product. Voor een eigen item — of een barcode die
    /// OpenFoodFacts niet kent — is dit de enige manier om van het grijze bestek af te komen.
    @ViewBuilder private var photoActions: some View {
        Menu {
            Button("Kies uit Foto's", systemImage: "photo.on.rectangle") { choosingPhoto = true }
            Button("Maak een foto", systemImage: "camera") { takingPhoto = true }
            if photo != nil {
                Button("Verwijder foto", systemImage: "trash", role: .destructive) {
                    ProductPhoto.remove(barcode: food.barcode, name: food.name)
                    photo = nil
                }
            }
        } label: {
            Label(photo == nil ? "Eigen foto" : "Foto wijzigen", systemImage: "camera")
                .font(.caption.weight(.semibold))
        }
        if photo != nil {
            Text("Eigen foto's blijven op dit toestel — ze gaan niet mee met de sync.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        if let photoError {
            Label(photoError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func savePhoto(_ data: Data) {
        do {
            try ProductPhoto.save(data, barcode: food.barcode, name: food.name)
            photo = food.localPhoto
            photoError = nil
        } catch {
            photoError = "Foto opslaan mislukt. Probeer het opnieuw."
        }
    }

    /// De thumbnail is 120 pt; de foto van OpenFoodFacts is groter. Tikken toont 'm op
    /// volle breedte, zodat je het etiket kunt lezen. Tik of veeg om te sluiten.
    private var photoPreview: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Group {
                if let photo, let ui = UIImage(contentsOfFile: photo.path) {
                    Image(uiImage: ui).resizable().scaledToFit()
                } else {
                    AsyncImage(url: URL(string: food.imageURL)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().tint(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Foto van \(food.name)")

            Button { showPhoto = false } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Sluit")
        }
        .contentShape(Rectangle())
        .onTapGesture { showPhoto = false }
    }

    private func macroTile(_ label: String, _ value: Int, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }

    private func per100Row(_ label: String, _ value: Double, _ unit: String) -> some View {
        LabeledContent(label) {
            Text("\(value.kgText) \(unit)").monospacedDigit()
        }
        .font(.subheadline)
    }
}

// MARK: - Nieuw product (barcode onbekend)

struct FoodPortionSheet: View {
    @State var food: FoodLogSheet.PendingFood
    var meal: String
    var entryDate: Date
    var onLogged: (String) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]
    @State private var portionAmount = 100
    @State private var portionUnit: FoodUnit = .gram

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Naam", text: $food.name)
                    macroField("Eiwit", $food.protein100)
                    macroField("Kcal", $food.kcal100)
                    macroField("Koolhydraten", $food.carbs100)
                    macroField("Vet", $food.fat100)
                } header: {
                    Text("Barcode \(food.barcode)")
                } footer: {
                    Text("Per 100 \(food.unit.label). Blijft aan deze barcode hangen, dus dit hoef je maar één keer te doen.")
                }
                if !food.name.trimmingCharacters(in: .whitespaces).isEmpty, food.protein100 + food.kcal100 > 0 {
                    Section("Portie") {
                        PortionEditor(food: food, lastAmount: 0,
                                      amount: $portionAmount, unit: $portionUnit) { amount, unit in
                            log(amount: amount, unit: unit)
                        }
                    }
                }
            }
            .navigationTitle("Nieuw product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func macroField(_ label: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
        }
    }

    private func log(amount: Int, unit: FoodUnit) {
        let product = FoodProduct(name: food.name, brand: food.brand, barcode: food.barcode,
                                  protein100: food.protein100, kcal100: food.kcal100,
                                  carbs100: food.carbs100, fat100: food.fat100)
        product.unit = unit.rawValue
        product.lastAmount = Double(amount)
        context.insert(product)

        func scaled(_ per100: Double) -> Int { Int((per100 * Double(amount) / 100).rounded()) }
        context.insert(ProteinEntry(date: entryDate, grams: scaled(food.protein100), label: food.name,
                                    kcal: scaled(food.kcal100), carbs: scaled(food.carbs100),
                                    fat: scaled(food.fat100), meal: meal,
                                    amount: Double(amount), unit: unit))
        dismiss()
        onLogged(food.name)
    }
}

// MARK: - Barcode-camera (VisionKit)

/// `startScanning()` werkt pas als de view daadwerkelijk zichtbaar is. Vanuit
/// `makeUIViewController` aanroepen is te vroeg: het gooit, en met `try?` zag je
/// alleen een zwart vlak. `DataScannerViewController` is niet `open`, dus geen
/// subclass — we hosten 'm als child en starten in ónze `viewDidAppear`.
final class ScannerHostController: UIViewController {
    private let scanner: DataScannerViewController
    var onStartFailure: ((Error) -> Void)?

    init(scanner: DataScannerViewController) {
        self.scanner = scanner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) wordt niet gebruikt") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !scanner.isScanning else { return }
        do { try scanner.startScanning() } catch { onStartFailure?(error) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanner.stopScanning() // camera vrijgeven zodra je de tab verlaat
    }
}

/// Camera voor een productfoto. `PhotosPicker` kan alleen kiezen uit wat er al staat,
/// niet iets nieuws maken — en een pot uit je eigen keuken staat nergens in Foto's.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Verkleinen doet `ProductPhoto`; hier gaat de foto er ongemoeid in.
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 1) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct BarcodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerHostController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()],
                                                qualityLevel: .fast,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        let host = ScannerHostController(scanner: scanner)
        host.onStartFailure = { onFailure(Self.message(for: $0)) }
        return host
    }

    func updateUIViewController(_ vc: ScannerHostController, context: Context) {}

    /// Zeg wát er mis is; "werkt niet" is geen foutmelding.
    private static func message(for error: Error) -> String {
        guard let e = error as? DataScannerViewController.ScanningUnavailable else {
            return "Scannen kon niet starten: \(error.localizedDescription)"
        }
        return switch e {
        case .cameraRestricted: "Geen toegang tot de camera. Zet 'm aan in Instellingen → Built."
        case .unsupported: "Dit toestel ondersteunt scannen niet. Voer de barcode hieronder in."
        @unknown default: "Scannen kon niet starten. Voer de barcode hieronder in."
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var lastCode = ""
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in added {
                guard let code = barcode.payloadStringValue, code != lastCode else { continue }
                lastCode = code
                onScan(code)
            }
        }
    }
}


/// Weekrapport: gemiddeld eiwit/kcal, adherence en beste/slechtste dag (7 dagen).
struct NutritionReportSheet: View {
    let profile: Profile
    let kcalTarget: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var proteins: [ProteinEntry]

    private var cal: Calendar { .current }

    private struct DayTotal { let day: Date; let protein: Int; let kcal: Int }

    private var last7: [DayTotal] {
        (0..<7).reversed().compactMap { offset -> DayTotal? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: .now)) else { return nil }
            let entries = proteins.filter { dayKey($0.date) == dayKey(day) }
            return DayTotal(day: day, protein: entries.map(\.grams).reduce(0, +), kcal: entries.map(\.kcal).reduce(0, +))
        }
    }

    private var loggedDays: [DayTotal] { last7.filter { $0.protein > 0 || $0.kcal > 0 } }
    private var avgProtein: Int { loggedDays.isEmpty ? 0 : loggedDays.map(\.protein).reduce(0, +) / loggedDays.count }
    private var avgKcal: Int { loggedDays.isEmpty ? 0 : loggedDays.map(\.kcal).reduce(0, +) / loggedDays.count }
    private var adherence: Int {
        let hit = last7.filter { $0.protein >= profile.proteinTarget }.count
        return Int((Double(hit) / 7 * 100).rounded())
    }
    private var best: DayTotal? { loggedDays.max { $0.protein < $1.protein } }
    private var worst: DayTotal? { loggedDays.min { $0.protein < $1.protein } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        StatTile(value: "\(avgProtein) g", label: "eiwit/dag", size: .compact)
                        Divider()
                        StatTile(value: "\(avgKcal)", label: "kcal/dag", size: .compact)
                        Divider()
                        StatTile(value: "\(adherence)%", label: "eiwitdoel gehaald", size: .compact)
                    }
                } header: {
                    Text("Gemiddelde — laatste 7 dagen")
                }

                Section("Per dag") {
                    ForEach(last7, id: \.day) { d in
                        HStack {
                            Text(d.day.formatted(.dateTime.weekday(.wide)))
                            Spacer()
                            Text(d.protein >= profile.proteinTarget ? "\(d.protein) g ✓" : "\(d.protein) g")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(d.protein >= profile.proteinTarget ? .green : .secondary)
                        }
                    }
                }

                if let best, let worst {
                    Section("Uitschieters") {
                        LabeledContent("Beste dag", value: "\(best.day.formatted(.dateTime.weekday(.abbreviated))) · \(best.protein) g")
                        LabeledContent("Zwakste dag", value: "\(worst.day.formatted(.dateTime.weekday(.abbreviated))) · \(worst.protein) g")
                    }
                }
            }
            .navigationTitle("Weekrapport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } }
            }
        }
    }

}
