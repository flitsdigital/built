import SwiftUI
import SwiftData
import VisionKit

// MARK: - OpenFoodFacts (gratis, geen key)

enum OFF {
    // OFF throttelt zonder User-Agent → eigen sessie met UA, korte timeout en cache.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": "Built/1.0 (iOS; support@builtapp.nl)"]
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 40 << 20)
        return URLSession(configuration: cfg)
    }()
    private static var queryCache: [String: [Product]] = [:]

    struct Product: Identifiable {
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
    }

    private struct LookupResponse: Decodable { var product: RawProduct? }
    private struct SearchResponse: Decodable { var products: [RawProduct] }
    private struct SaLResponse: Decodable { var hits: [RawProduct] }
    private struct RawProduct: Decodable {
        var code: String?
        var product_name: String?
        var brands: String?
        var image_front_small_url: String?
        var serving_quantity: FlexibleDouble?
        var serving_quantity_unit: String?
        var product_quantity: FlexibleDouble?
        var nutriments: Nutriments?
    }

    /// OFF levert hoeveelheden soms als getal, soms als string ("250").
    struct FlexibleDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            value = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
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

        // OFF levert soms getallen als string
        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Double? {
            (try? c.decode(Double.self, forKey: k))
                ?? (try? c.decode(String.self, forKey: k)).flatMap(Double.init)
        }
    }

    private static func product(from raw: RawProduct) -> Product? {
        guard let name = raw.product_name, !name.isEmpty, let n = raw.nutriments,
              n.proteins != nil || n.kcal != nil else { return nil }
        func sane(_ v: Double?, _ upper: Double) -> Double {
            guard let v, v >= 1, v <= upper else { return 0 }
            return v
        }
        return Product(name: name, brand: raw.brands ?? "", barcode: raw.code ?? "",
                       protein100: n.proteins ?? 0, kcal100: n.kcal ?? 0,
                       carbs100: n.carbs ?? 0, fat100: n.fat ?? 0,
                       imageURL: raw.image_front_small_url ?? "",
                       servingGrams: sane(raw.serving_quantity?.value, 1500),
                       packageGrams: sane(raw.product_quantity?.value, 5000))
    }

    static func lookup(barcode: String) async -> Product? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=code,product_name,brands,nutriments,image_front_small_url,serving_quantity,serving_quantity_unit,product_quantity"),
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let raw = response.product else { return nil }
        return product(from: raw)
    }

    /// nil = OpenFoodFacts niet bereikbaar; [] = echt geen resultaten.
    static func search(_ query: String) async -> [Product]? {
        let key = query.lowercased()
        if let cached = queryCache[key] { return cached }   // eerder gezocht → instant
        // Beide endpoints tegelijk: de eerste met resultaten wint. Zo faalt zoeken
        // alleen als béíde onbereikbaar zijn, i.p.v. te wachten op één trage endpoint.
        let result: [Product]? = await withTaskGroup(of: [Product]?.self) { group in
            group.addTask { await salSearch(query) }
            group.addTask { await legacySearch(query) }
            var reachable = false
            for await r in group {
                if let r, !r.isEmpty { group.cancelAll(); return r }
                if r != nil { reachable = true } // [] = bereikbaar maar leeg
            }
            return reachable ? [] : nil
        }
        if let result, !result.isEmpty { queryCache[key] = result }
        return result
    }

    /// search-a-licious: populariteit-gesorteerd, NL bovenaan. Snel maar wisselvallig.
    private static func salSearch(_ query: String) async -> [Product]? {
        var comps = URLComponents(string: "https://search.openfoodfacts.org/search")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "langs", value: "nl,en"),
            .init(name: "sort_by", value: "-popularity_key"),
            .init(name: "page_size", value: "20"),
            .init(name: "fields", value: "code,product_name,brands,nutriments,image_front_small_url,serving_quantity,serving_quantity_unit,product_quantity"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(SaLResponse.self, from: data) else { return nil }
        return response.hits.compactMap(product(from:))
    }

    private static func legacySearch(_ query: String) async -> [Product]? {
        var comps = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        comps.queryItems = [
            .init(name: "search_terms", value: query),
            .init(name: "search_simple", value: "1"),
            .init(name: "action", value: "process"),
            .init(name: "json", value: "1"),
            .init(name: "page_size", value: "20"),
            .init(name: "fields", value: "code,product_name,brands,nutriments,image_front_small_url,serving_quantity,product_quantity"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        return response.products.compactMap(product(from:))
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
    }
}

// MARK: - Eten-tab

struct FoodView: View {
    let profile: Profile
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
        proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
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
        List {
            Section {
                dayHeader
                summaryRow
            }
            .listRowSeparator(.hidden)

            ForEach(mealOrder, id: \.self) { meal in
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
                Button { showReport = true } label: { Image(systemName: "chart.bar.doc.horizontal") }
                    .accessibilityLabel("Weekrapport")
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
                        Text(mealNames[meal] ?? meal)
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
                for i in offsets { context.delete(list[i]) }
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
    @State private var pending: PendingFood?
    @State private var scanError: String?
    @State private var manualBarcode = ""
    @State private var lookingUp = false
    // Snel toevoegen
    @State private var quickLabel = ""
    @State private var quickProtein: Int?
    @State private var quickKcal: Int?
    @State private var quickCarbs: Int?
    @State private var quickFat: Int?

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
            .navigationTitle("Loggen — \(mealNames[meal] ?? meal)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { dismiss() }
                }
            }
            .sheet(item: $pending) { food in
                FoodPortionSheet(food: food, meal: meal, entryDate: entryDate) {
                    dismiss()
                }
            }
        }
    }

    // MARK: Zoeken

    private var searchTab: some View {
        List {
            Section {
                TextField("Zoek product (bijv. kwark)", text: $query)
                    .autocorrectionDisabled()
            }
            let own = ownMatches
            if !own.isEmpty {
                Section("Jouw producten") {
                    ForEach(own) { product in
                        Button {
                            pending = PendingFood(name: product.name, brand: product.brand, barcode: product.barcode,
                                                  protein100: product.protein100, kcal100: product.kcal100,
                                                  carbs100: product.carbs100, fat100: product.fat100,
                                                  imageURL: product.imageURL,
                                                  servingGrams: product.servingGrams, servingName: product.servingName)
                        } label: {
                            productRow(product.name, product.brand, product.protein100, product.kcal100,
                                       favorite: product.favorite, imageURL: product.imageURL)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(own[i]) }
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
                        Button {
                            pending = PendingFood(name: product.name, brand: product.brand, barcode: product.barcode,
                                                  protein100: product.protein100, kcal100: product.kcal100,
                                                  carbs100: product.carbs100, fat100: product.fat100,
                                                  imageURL: product.imageURL,
                                                  servingGrams: product.servingGrams, packageGrams: product.packageGrams)
                        } label: {
                            productRow(product.name, product.brand, product.protein100, product.kcal100,
                                       favorite: false, imageURL: product.imageURL)
                        }
                        .buttonStyle(.plain)
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

    private func productRow(_ name: String, _ brand: String, _ p100: Double, _ k100: Double,
                            favorite: Bool, imageURL: String) -> some View {
        HStack(spacing: 10) {
            FoodThumb(url: imageURL)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
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
                if DataScannerViewController.isSupported {
                    BarcodeScanner { code in
                        handleBarcode(code)
                    }
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                } else {
                    Label("Camera niet beschikbaar (simulator). Voer de barcode hieronder in.", systemImage: "camera.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Richt op de streepjescode van het product. Gevonden via OpenFoodFacts.")
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
    }

    private func handleBarcode(_ code: String) {
        guard !lookingUp, pending == nil else { return }
        scanError = nil
        // Eigen producten winnen: eerder gescand = direct raak, ook offline
        if let known = products.first(where: { $0.barcode == code }) {
            pending = PendingFood(name: known.name, brand: known.brand, barcode: known.barcode,
                                  protein100: known.protein100, kcal100: known.kcal100,
                                  carbs100: known.carbs100, fat100: known.fat100,
                                  imageURL: known.imageURL,
                                  servingGrams: known.servingGrams, servingName: known.servingName)
            return
        }
        lookingUp = true
        Task {
            let found = await OFF.lookup(barcode: code)
            lookingUp = false
            if let found {
                pending = PendingFood(name: found.name, brand: found.brand, barcode: found.barcode,
                                      protein100: found.protein100, kcal100: found.kcal100,
                                      carbs100: found.carbs100, fat100: found.fat100,
                                      imageURL: found.imageURL,
                                      servingGrams: found.servingGrams, packageGrams: found.packageGrams)
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
                Button {
                    let grams = quickProtein ?? 0
                    context.insert(ProteinEntry(date: entryDate, grams: grams,
                                                label: quickLabel.isEmpty ? "Eigen maaltijd" : quickLabel,
                                                kcal: quickKcal ?? 0, carbs: quickCarbs ?? 0, fat: quickFat ?? 0,
                                                meal: meal))
                    dismiss()
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

    // MARK: Recepten

    private var recipesTab: some View {
        List {
            Section {
                ForEach(recipes.filter { $0.proteinPerServing > 0 }) { recipe in
                    Button {
                        context.insert(ProteinEntry(date: entryDate, grams: recipe.proteinPerServing,
                                                    label: recipe.name, kcal: recipe.kcalPerServing, meal: meal))
                        dismiss()
                    } label: {
                        HStack {
                            Text(recipe.name).foregroundStyle(.primary)
                            if recipe.favorite {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
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

// MARK: - Portie kiezen

struct FoodPortionSheet: View {
    @State var food: FoodLogSheet.PendingFood
    var meal: String
    var entryDate: Date
    var onLogged: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]

    @State private var grams: Int = 100
    @State private var favorite = false
    @State private var mealChoice = ""
    @State private var showOwnPortion = false
    @State private var portionNameInput = ""
    @State private var portionGramsInput = ""

    private var unitName: String {
        food.servingName.isEmpty ? "portie" : food.servingName
    }

    private var effectiveGrams: Int { grams }
    private func scaled(_ per100: Double) -> Int { Int((per100 * Double(effectiveGrams) / 100).rounded()) }

    var body: some View {
        NavigationStack {
            List {
                if food.editable {
                    Section("Nieuw product (barcode \(food.barcode))") {
                        TextField("Naam", text: $food.name)
                        LabeledContent("Eiwit /100 g") {
                            TextField("10", value: $food.protein100, format: .number)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        }
                        LabeledContent("Kcal /100 g") {
                            TextField("100", value: $food.kcal100, format: .number)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        }
                        LabeledContent("Koolh. /100 g") {
                            TextField("0", value: $food.carbs100, format: .number)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        }
                        LabeledContent("Vet /100 g") {
                            TextField("0", value: $food.fat100, format: .number)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            FoodThumb(url: food.imageURL, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(food.name).font(.headline)
                                if !food.brand.isEmpty {
                                    Text(food.brand).font(.footnote).foregroundStyle(.secondary)
                                }
                                Text("Per 100 g: \(Int(food.protein100.rounded())) g eiwit · \(Int(food.kcal100.rounded())) kcal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    HStack {
                        TextField("100", value: $grams, format: .number)
                            .keyboardType(.numberPad)
                            .font(.title3.bold().monospacedDigit())
                            .frame(width: 70)
                        Text("gram").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([50, 100, 250], id: \.self) { preset in
                            Button("\(preset)") { grams = preset }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .tint(grams == preset ? .green : .secondary)
                        }
                    }
                    // Snelle porties (zetten alleen de grammen)
                    if food.servingGrams > 0 {
                        HStack {
                            Text("Per \(unitName): \(Int(food.servingGrams)) g")
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            ForEach([("½", 0.5), ("1", 1.0), ("2", 2.0)], id: \.0) { label, mult in
                                Button(label) { grams = Int((food.servingGrams * mult).rounded()) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .tint(.green)
                            }
                        }
                    }
                    if food.packageGrams > 0 {
                        Button {
                            grams = Int(food.packageGrams)
                        } label: {
                            Label("Heel pak (\(Int(food.packageGrams)) g)", systemImage: "shippingbox")
                                .font(.footnote)
                        }
                    }
                    Picker("Maaltijd", selection: $mealChoice) {
                        ForEach(mealOrder, id: \.self) { m in
                            Text(mealNames[m] ?? m).tag(m)
                        }
                    }
                    Toggle("Favoriet", isOn: $favorite)
                    Button {
                        portionNameInput = food.servingName
                        portionGramsInput = food.servingGrams > 0 ? "\(Int(food.servingGrams))" : ""
                        showOwnPortion = true
                    } label: {
                        Label(food.servingGrams > 0 ? "Eigen portie (\(Int(food.servingGrams)) g)" : "Eigen portie instellen…",
                              systemImage: "scalemass")
                            .font(.footnote)
                    }
                } header: {
                    Text("Portie")
                }

            }
            .safeAreaInset(edge: .bottom) {
                // Logknop altijd in beeld, ook op de halve sheet-hoogte
                VStack(spacing: 6) {
                    Button {
                        log()
                    } label: {
                        Text("Log \(scaled(food.protein100)) g eiwit · \(scaled(food.kcal100)) kcal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(effectiveGrams <= 0 || (food.editable && food.name.trimmingCharacters(in: .whitespaces).isEmpty))
                    if food.carbs100 > 0 || food.fat100 > 0 {
                        Text("Ook: \(scaled(food.carbs100)) g koolhydraten · \(scaled(food.fat100)) g vet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.regularMaterial)
            }
            .navigationTitle("Portie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Terug") { dismiss() }
                }
            }
            .onAppear {
                if mealChoice.isEmpty { mealChoice = meal }
                let existing = products.first { !food.barcode.isEmpty && $0.barcode == food.barcode }
                favorite = existing?.favorite ?? false
                if food.servingGrams > 0 { grams = Int(food.servingGrams) } // 1 portie is de logische default
            }
            .alert("Eigen portie", isPresented: $showOwnPortion) {
                TextField("Naam (bijv. ei, bakje)", text: $portionNameInput)
                TextField("Gram per stuk", text: $portionGramsInput)
                    .keyboardType(.numberPad)
                Button("Opslaan") {
                    if let g = Double(portionGramsInput.replacingOccurrences(of: ",", with: ".")), g > 0 {
                        food.servingGrams = g
                        food.servingName = portionNameInput.trimmingCharacters(in: .whitespaces)
                        grams = Int(g)
                    }
                }
                Button("Annuleer", role: .cancel) {}
            } message: {
                Text("Wordt op het product bewaard — volgende keer log je gewoon \"1 \(portionNameInput.isEmpty ? "portie" : portionNameInput)\".")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func log() {
        // Product bewaren/bijwerken zodat scannen en zoeken 'm volgende keer lokaal vinden
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
        if food.editable {
            product.name = food.name
            product.protein100 = food.protein100
            product.kcal100 = food.kcal100
            product.carbs100 = food.carbs100
            product.fat100 = food.fat100
        }
        if food.servingGrams > 0 {
            product.servingGrams = food.servingGrams
            product.servingName = food.servingName
        }
        product.favorite = favorite
        product.lastUsed = .now

        context.insert(ProteinEntry(date: entryDate, grams: scaled(food.protein100), label: food.name,
                                    kcal: scaled(food.kcal100), carbs: scaled(food.carbs100),
                                    fat: scaled(food.fat100), meal: mealChoice))
        dismiss()
        onLogged()
    }
}

// MARK: - Barcode-camera (VisionKit)

struct BarcodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode()],
                                           qualityLevel: .fast,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

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
            let entries = proteins.filter { cal.isDate($0.date, inSameDayAs: day) }
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
