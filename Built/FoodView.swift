import SwiftUI
import SwiftData
import VisionKit
import AVFoundation

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

    private static let cacheURL = URL.cachesDirectory.appendingPathComponent("off_query_cache.json")
    private static var queryCache: [String: [Product]] =
        (try? JSONDecoder().decode([String: [Product]].self, from: Data(contentsOf: cacheURL))) ?? [:]
    private static func persistCache() { try? JSONEncoder().encode(queryCache).write(to: cacheURL) }

    // MARK: - Zoeken

    /// nil = OFF niet bereikbaar; [] = echt geen resultaten.
    static func search(_ query: String) async -> [Product]? {
        let key = query.lowercased()
        if let cached = queryCache[key] { return cached } // eerder gezocht → instant
        var result = await raceSearch(query)
        if result == nil { // storing → één korte retry voordat we opgeven
            try? await Task.sleep(for: .milliseconds(600))
            result = await raceSearch(query)
        }
        if let result, !result.isEmpty {
            queryCache[key] = result
            persistCache()
        }
        return result
    }

    /// Drie endpoints tegelijk; de eerste met resultaten wint. Zo faalt zoeken alleen
    /// als álle drie onbereikbaar zijn — één trage/platte server blokkeert niets.
    private static func raceSearch(_ query: String) async -> [Product]? {
        await withTaskGroup(of: [Product]?.self) { group in
            group.addTask { await sal(query) }
            group.addTask { await cgi("https://nl.openfoodfacts.org/cgi/search.pl", query) }
            group.addTask { await cgi("https://world.openfoodfacts.org/cgi/search.pl", query) }
            var reachable = false
            for await r in group {
                if let r, !r.isEmpty { group.cancelAll(); return r }
                if r != nil { reachable = true } // [] = bereikbaar maar leeg
            }
            return reachable ? [] : nil
        }
    }

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

    private static func cgi(_ base: String, _ query: String) async -> [Product]? {
        var c = URLComponents(string: base)!
        c.queryItems = [.init(name: "search_terms", value: query), .init(name: "search_simple", value: "1"),
                        .init(name: "action", value: "process"), .init(name: "json", value: "1"),
                        .init(name: "page_size", value: "20"), .init(name: "fields", value: fields)]
        guard let url = c.url, let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        return r.products.items.compactMap(product(from:))
    }

    // MARK: - Barcode (met retry)

    static func lookup(barcode: String) async -> Product? {
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
    private struct SearchResponse: Decodable { var products: Lenient<RawProduct> }
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

/// Productfoto met vork-fallback; AsyncImage cachet via URLCache.
struct FoodThumb: View {
    var url: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: URL(string: url)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "fork.knife")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.tertiary)
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
            }
            .buttonStyle(.plain)

            ForEach(list) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    HStack(spacing: 10) {
                        FoodThumb(url: products.first(where: { $0.name == entry.label })?.imageURL ?? "", size: 34)
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
    /// Welke rij is uitgeklapt (barcode, of naam als die er niet is). nil = geen.
    @State private var expandedKey: String?
    /// Zojuist gescand product; krijgt dezelfde portie-editor als een zoekrij.
    @State private var scanned: PendingFood?
    @State private var scanError: String?
    @State private var manualBarcode = ""
    @State private var cameraDenied = false
    @State private var lookingUp = false
    // Snel toevoegen
    @State private var quickLabel = ""
    @State private var quickProtein: Int?
    @State private var quickKcal: Int?
    @State private var quickCarbs: Int?
    @State private var quickFat: Int?
    @State private var quickSave = false
    /// Labels van wat je in deze sessie hebt gelogd — voedt de balk onderin.
    @State private var added: [String] = []
    @Query private var todaysEntries: [ProteinEntry]

    struct PendingFood: Identifiable {
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
                    Text("Snel").tag(2)
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let own = ownMatches
            if !own.isEmpty {
                Section("Jouw producten") {
                    ForEach(own) { product in
                        let food = PendingFood(name: product.name, brand: product.brand, barcode: product.barcode,
                                               protein100: product.protein100, kcal100: product.kcal100,
                                               carbs100: product.carbs100, fat100: product.fat100,
                                               imageURL: product.imageURL,
                                               servingGrams: product.servingGrams, servingName: product.servingName,
                                               unit: product.foodUnit, categories: product.categoryList)
                        expandableRow(food, favorite: product.favorite, lastAmount: product.lastAmount)
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
                        for i in offsets { context.deleteSynced(own[i]) }
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
                        Text("Niets gevonden. Probeer de scanner of voeg zelf toe via Snel.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { product in
                        expandableRow(PendingFood(name: product.name, brand: product.brand, barcode: product.barcode,
                                                  protein100: product.protein100, kcal100: product.kcal100,
                                                  carbs100: product.carbs100, fat100: product.fat100,
                                                  imageURL: product.imageURL,
                                                  servingGrams: product.servingGrams, packageGrams: product.packageGrams,
                                                  unit: product.unit, categories: product.categories),
                                      favorite: false,
                                      lastAmount: products.first { !$0.barcode.isEmpty && $0.barcode == product.barcode }?.lastAmount ?? 0)
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

    /// Rij die uitklapt met de portie-editor eronder. Tikken op een andere rij vouwt
    /// de vorige dicht — er staat er dus altijd hoogstens één open.
    @ViewBuilder private func expandableRow(_ food: PendingFood, favorite: Bool, lastAmount: Double) -> some View {
        let key = food.barcode.isEmpty ? food.name : food.barcode
        let open = expandedKey == key
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expandedKey = open ? nil : key }
            } label: {
                HStack(spacing: 10) {
                    productRow(food.name, food.brand, food.protein100, food.kcal100,
                               favorite: favorite, imageURL: food.imageURL)
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            if open {
                PortionEditor(food: food, lastAmount: lastAmount) { amount, unit in
                    logFood(food, amount: amount, unit: unit)
                    withAnimation(.snappy(duration: 0.25)) { expandedKey = nil }
                }
                .id(key) // verse staat per product
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

    private func productRow(_ name: String, _ brand: String, _ p100: Double, _ k100: Double,
                            favorite: Bool, imageURL: String) -> some View {
        HStack(spacing: 10) {
            FoodThumb(url: imageURL)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Favoriet")
                    }
                }
                if !brand.isEmpty {
                    Text(brand).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(Int(p100.rounded())) g · \(Int(k100.rounded())) kcal")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
                    productRow(scanned.name, scanned.brand, scanned.protein100, scanned.kcal100,
                               favorite: false, imageURL: scanned.imageURL)
                    PortionEditor(food: scanned,
                                  lastAmount: products.first { !scanned.barcode.isEmpty && $0.barcode == scanned.barcode }?.lastAmount ?? 0) { amount, unit in
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
            scanned = PendingFood(name: known.name, brand: known.brand, barcode: known.barcode,
                                  protein100: known.protein100, kcal100: known.kcal100,
                                  carbs100: known.carbs100, fat100: known.fat100,
                                  imageURL: known.imageURL,
                                  servingGrams: known.servingGrams, servingName: known.servingName,
                                  unit: known.foodUnit, categories: known.categoryList)
            return
        }
        lookingUp = true
        Task {
            let found = await OFF.lookup(barcode: code)
            lookingUp = false
            if let found {
                scanned = PendingFood(name: found.name, brand: found.brand, barcode: found.barcode,
                                      protein100: found.protein100, kcal100: found.kcal100,
                                      carbs100: found.carbs100, fat100: found.fat100,
                                      imageURL: found.imageURL,
                                      servingGrams: found.servingGrams, packageGrams: found.packageGrams,
                                      unit: found.unit, categories: found.categories)
            } else {
                // Niet in de database → één keer zelf invullen, blijft aan de barcode hangen
                pending = PendingFood(name: "", barcode: code, protein100: 0, kcal100: 0, editable: true)
            }
        }
    }

    // MARK: Snel

    private var quickTab: some View {
        List {
            Section {
                TextField("Omschrijving (bijv. kipfilet)", text: $quickLabel)
                LabeledContent("Eiwit") {
                    TextField("30", value: $quickProtein, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                }
                LabeledContent("Kcal") {
                    TextField("250", value: $quickKcal, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                }
                LabeledContent("Koolhydraten") {
                    TextField("0", value: $quickCarbs, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                }
                LabeledContent("Vet") {
                    TextField("0", value: $quickFat, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                }
            } footer: {
                Text("Alles in grammen behalve kcal. Alleen eiwit is verplicht.")
            }
            Section {
                Toggle("Bewaar als eigen maaltijd", isOn: $quickSave)
                    .disabled(quickLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(quickLabel.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Geef een omschrijving om te kunnen bewaren."
                     : "Zet \u{201C}\(quickLabel)\u{201D} bij je recepten, zodat je 'm later met één tik logt.")
            }
            Section {
                Button {
                    let grams = quickProtein ?? 0
                    let name = quickLabel.trimmingCharacters(in: .whitespaces)
                    context.insert(ProteinEntry(date: entryDate, grams: grams,
                                                label: name.isEmpty ? "Eigen maaltijd" : name,
                                                kcal: quickKcal ?? 0, carbs: quickCarbs ?? 0, fat: quickFat ?? 0,
                                                meal: meal))
                    if quickSave, !name.isEmpty { saveQuickAsMeal(name: name, protein: grams, kcal: quickKcal ?? 0) }
                    withAnimation(.snappy(duration: 0.25)) { added.append(name.isEmpty ? "Eigen maaltijd" : name) }
                    quickLabel = ""; quickProtein = nil; quickKcal = nil; quickCarbs = nil; quickFat = nil
                } label: {
                    Text("Log \(quickProtein ?? 0) g eiwit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled((quickProtein ?? 0) <= 0)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Bewaart een snelle invoer als herbruikbaar recept (bestaande naam wordt bijgewerkt).
    private func saveQuickAsMeal(name: String, protein: Int, kcal: Int) {
        if let existing = recipes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            existing.protein = protein
            existing.kcal = kcal
        } else {
            context.insert(Meal(name: name, protein: protein, kcal: kcal))
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
    var onLog: (Int, FoodUnit) -> Void

    @State private var amount = 100
    @State private var unit: FoodUnit = .gram

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

// MARK: - Nieuw product (barcode onbekend)

struct FoodPortionSheet: View {
    @State var food: FoodLogSheet.PendingFood
    var meal: String
    var entryDate: Date
    var onLogged: (String) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]

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
                        PortionEditor(food: food, lastAmount: 0) { amount, unit in
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
                        stat("\(avgProtein) g", "eiwit/dag")
                        Divider()
                        stat("\(avgKcal)", "kcal/dag")
                        Divider()
                        stat("\(adherence)%", "eiwitdoel gehaald")
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

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
