import SwiftUI
import SwiftData
import VisionKit

// MARK: - OpenFoodFacts (gratis, geen key)

enum OFF {
    struct Product: Identifiable {
        var id: String { barcode.isEmpty ? name : barcode }
        var name: String
        var brand: String
        var barcode: String
        var protein100: Double
        var kcal100: Double
        var carbs100: Double
        var fat100: Double
    }

    private struct LookupResponse: Decodable { var product: RawProduct? }
    private struct SearchResponse: Decodable { var products: [RawProduct] }
    private struct RawProduct: Decodable {
        var code: String?
        var product_name: String?
        var brands: String?
        var nutriments: Nutriments?
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
        return Product(name: name, brand: raw.brands ?? "", barcode: raw.code ?? "",
                       protein100: n.proteins ?? 0, kcal100: n.kcal ?? 0,
                       carbs100: n.carbs ?? 0, fat100: n.fat ?? 0)
    }

    static func lookup(barcode: String) async -> Product? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=code,product_name,brands,nutriments"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let raw = response.product else { return nil }
        return product(from: raw)
    }

    static func search(_ query: String) async -> [Product] {
        var comps = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        comps.queryItems = [
            .init(name: "search_terms", value: query),
            .init(name: "search_simple", value: "1"),
            .init(name: "action", value: "process"),
            .init(name: "json", value: "1"),
            .init(name: "page_size", value: "20"),
            .init(name: "fields", value: "code,product_name,brands,nutriments"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        return response.products.compactMap(product(from:))
    }
}

// MARK: - Eten-tab

struct FoodView: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query private var proteins: [ProteinEntry]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \Meal.createdAt) private var meals: [Meal]

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var logMeal: String?
    @State private var editingEntry: ProteinEntry?

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
        profile.kcalTargetEffective(currentWeight: weights.last?.kg ?? profile.startWeight)
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
        .navigationTitle("Eten")
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
            Button {
                withAnimation(.snappy(duration: 0.2)) { day = cal.date(byAdding: .day, value: -1, to: day)! }
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
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
            Button {
                withAnimation(.snappy(duration: 0.2)) { day = cal.date(byAdding: .day, value: 1, to: day)! }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isToday ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
            .disabled(isToday)
        }
        .padding(.vertical, 2)
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color(.systemFill), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: min(Double(totalProtein) / Double(max(profile.proteinTarget, 1)), 1))
                    .stroke(.green, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.5), value: totalProtein)
                VStack(spacing: 0) {
                    Text("\(totalProtein)")
                        .font(.title3.bold().monospacedDigit())
                    Text("van \(profile.proteinTarget) g")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totalKcal) / \(kcalTarget) kcal")
                        .font(.subheadline.bold().monospacedDigit())
                    ProgressView(value: min(Double(totalKcal) / Double(max(kcalTarget, 1)), 1))
                        .tint(totalKcal > kcalTarget ? .orange : .green)
                }
                HStack(spacing: 12) {
                    macroStat("Koolh.", totalCarbs)
                    macroStat("Vet", totalFat)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func macroStat(_ label: String, _ grams: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(grams) g")
                .font(.caption.bold().monospacedDigit())
        }
    }

    private func mealSection(_ meal: String) -> some View {
        let list = entries(for: meal)
        let protein = list.map(\.grams).reduce(0, +)
        let kcal = list.map(\.kcal).reduce(0, +)
        return Section {
            ForEach(list) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label)
                                .foregroundStyle(.primary)
                            if entry.kcal > 0 || entry.carbs > 0 || entry.fat > 0 {
                                Text("\(entry.kcal) kcal\(entry.carbs > 0 ? " · \(entry.carbs) K" : "")\(entry.fat > 0 ? " · \(entry.fat) V" : "")")
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
            Button {
                logMeal = meal
            } label: {
                Label("Toevoegen", systemImage: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            HStack {
                Text(mealNames[meal] ?? meal)
                Spacer()
                if protein > 0 {
                    Text("\(protein) g · \(kcal) kcal")
                        .textCase(nil)
                        .font(.caption.monospacedDigit())
                }
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
                                                  carbs100: product.carbs100, fat100: product.fat100)
                        } label: {
                            productRow(product.name, product.brand, product.protein100, product.kcal100, favorite: product.favorite)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if query.count >= 3 {
                Section("OpenFoodFacts") {
                    if searching {
                        HStack { ProgressView(); Text("Zoeken…").foregroundStyle(.secondary) }
                    } else if results.isEmpty {
                        Text("Niets gevonden. Probeer de scanner of voeg zelf toe via Snel.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { product in
                        Button {
                            pending = PendingFood(name: product.name, brand: product.brand, barcode: product.barcode,
                                                  protein100: product.protein100, kcal100: product.kcal100,
                                                  carbs100: product.carbs100, fat100: product.fat100)
                        } label: {
                            productRow(product.name, product.brand, product.protein100, product.kcal100, favorite: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: query) {
            guard query.count >= 3 else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(400)) // debounce
            guard !Task.isCancelled else { return }
            results = await OFF.search(query)
            searching = false
        }
    }

    private var ownMatches: [FoodProduct] {
        let base = query.isEmpty
            ? products
            : products.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.brand.localizedCaseInsensitiveContains(query) }
        return Array(base.sorted { ($0.favorite ? 0 : 1, $1.lastUsed) < (($1.favorite ? 0 : 1), $0.lastUsed) }.prefix(10))
    }

    private func productRow(_ name: String, _ brand: String, _ p100: Double, _ k100: Double, favorite: Bool) -> some View {
        HStack {
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
                                  carbs100: known.carbs100, fat100: known.fat100)
            return
        }
        lookingUp = true
        Task {
            let found = await OFF.lookup(barcode: code)
            lookingUp = false
            if let found {
                pending = PendingFood(name: found.name, brand: found.brand, barcode: found.barcode,
                                      protein100: found.protein100, kcal100: found.kcal100,
                                      carbs100: found.carbs100, fat100: found.fat100)
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

    private func scaled(_ per100: Double) -> Int { Int((per100 * Double(grams) / 100).rounded()) }

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(food.name).font(.headline)
                            if !food.brand.isEmpty {
                                Text(food.brand).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("Per 100 g: \(Int(food.protein100.rounded())) g eiwit · \(Int(food.kcal100.rounded())) kcal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Portie") {
                    HStack {
                        TextField("100", value: $grams, format: .number)
                            .keyboardType(.numberPad)
                            .font(.title3.bold().monospacedDigit())
                            .frame(width: 80)
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
                    Picker("Maaltijd", selection: $mealChoice) {
                        ForEach(mealOrder, id: \.self) { m in
                            Text(mealNames[m] ?? m).tag(m)
                        }
                    }
                    Toggle("Favoriet", isOn: $favorite)
                }

                Section {
                    Button {
                        log()
                    } label: {
                        Text("Log \(scaled(food.protein100)) g eiwit · \(scaled(food.kcal100)) kcal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(grams <= 0 || (food.editable && food.name.trimmingCharacters(in: .whitespaces).isEmpty))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                } footer: {
                    if food.carbs100 > 0 || food.fat100 > 0 {
                        Text("Ook: \(scaled(food.carbs100)) g koolhydraten · \(scaled(food.fat100)) g vet")
                    }
                }
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
            context.insert(product)
        }
        if food.editable {
            product.name = food.name
            product.protein100 = food.protein100
            product.kcal100 = food.kcal100
            product.carbs100 = food.carbs100
            product.fat100 = food.fat100
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
