import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Kaart op de Eten-tab
//
// De enige ingang naar het kookboek. Vandaag iets gepland of bezig → dat gerecht, met
// Klaar-knop. Anders de teller.

struct CookbookCard: View {
    @Query(sort: \Dish.createdAt) private var dishes: [Dish]
    @Query private var cooks: [Cook]

    private var today: Cook? {
        cooks.filter { !$0.done && dayKey($0.date) <= dayKey(.now) }.min { $0.date < $1.date }
    }
    private var triedCount: Int {
        Set(cooks.filter(\.done).map(\.dishID)).count
    }

    var body: some View {
        if let today, let dish = dishes.first(where: { $0.syncID == today.dishID }) {
            NavigationLink { DishView(dish: dish) } label: {
                HStack(spacing: 12) {
                    DishImage(dish: dish, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vanavond").font(.caption).foregroundStyle(.secondary)
                        Text(dish.name).font(.headline).lineLimit(2)
                    }
                    Spacer()
                    Button("Klaar") { today.done = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                }
            }
        } else {
            NavigationLink { CookbookView() } label: {
                Label {
                    LabeledContent("Kookboek") {
                        let untried = dishes.count - triedCount
                        Text(dishes.isEmpty ? "" : "\(dishes.count) gerechten" + (untried > 0 ? " · \(untried) nog te proberen" : ""))
                    }
                } icon: {
                    Image(systemName: "book.closed").foregroundStyle(.green)
                }
            }
        }
    }
}

// MARK: - Foto en sterren

/// Eigen foto gaat vóór die van de site; zonder beide een bord.
struct DishImage: View {
    let dish: Dish
    var size: CGFloat = 56
    var body: some View {
        FoodThumb(url: dish.imageURL, size: size, photo: DishPhoto.existing(dish))
    }
}

struct Stars: View {
    @Binding var rating: Int
    var size: Font = .title3
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(size)
                    .foregroundStyle(i <= rating ? .yellow : .secondary)
                    .onTapGesture { rating = rating == i ? 0 : i }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(rating) van 5 sterren")
        .accessibilityAdjustableAction { d in
            rating = min(5, max(0, rating + (d == .increment ? 1 : -1)))
        }
    }
}

// MARK: - Kookboek

struct CookbookView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Dish.createdAt, order: .reverse) private var dishes: [Dish]
    @Query private var cooks: [Cook]
    @State private var query = ""
    /// nil = alles, "✓" = gemaakt, "?" = nog te proberen, anders een label.
    @State private var filter: String?
    @State private var showAdd = false

    private var lastCooked: [UUID: Date] {
        Dictionary(cooks.filter(\.done).map { ($0.dishID, $0.date) }, uniquingKeysWith: max)
    }
    private var cookCount: [UUID: Int] {
        Dictionary(cooks.filter(\.done).map { ($0.dishID, 1) }, uniquingKeysWith: +)
    }
    private var planned: [Cook] { cooks.filter { !$0.done }.sorted { $0.date < $1.date } }
    private var allLabels: [String] {
        Array(Set(dishes.flatMap(\.labels))).sorted()
    }

    private var shown: [Dish] {
        let last = lastCooked
        return dishes.filter { d in
            switch filter {
            case "✓": last[d.syncID] != nil
            case "?": last[d.syncID] == nil
            case let label?: d.labels.contains(label)
            case nil: true
            }
        }
        .filter { query.isEmpty || foodMatchScore($0.name, query: query) > 0
            || $0.labels.contains { foodMatchScore($0, query: query) > 0 } }
        .sorted { a, b in
            // Laatst gemaakt bovenaan; nog-te-proberen op datum toegevoegd erna.
            switch (last[a.syncID], last[b.syncID]) {
            case let (x?, y?): x > y
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        List {
            if !planned.isEmpty {
                Section("Gepland") {
                    ForEach(planned) { cook in
                        if let dish = dishes.first(where: { $0.syncID == cook.dishID }) {
                            NavigationLink { DishView(dish: dish) } label: {
                                HStack(spacing: 10) {
                                    Text(dayKey(cook.date) <= dayKey(.now) ? "vandaag" : cook.date.formatted(.dateTime.weekday(.abbreviated).day()))
                                        .font(.caption.bold()).foregroundStyle(.green)
                                        .frame(width: 56, alignment: .leading)
                                    Text(dish.name).lineLimit(1)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Weg", systemImage: "trash", role: .destructive) { context.deleteSynced(cook) }
                            }
                        }
                    }
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Alles", nil)
                        chip("Gemaakt", "✓")
                        chip("Nog te proberen", "?")
                        ForEach(allLabels, id: \.self) { chip($0, $0) }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if dishes.isEmpty {
                    ContentUnavailableView("Nog geen gerechten", systemImage: "book.closed",
                                           description: Text("Plak een link naar een recept, of voeg er zelf een toe."))
                }
                ForEach(shown) { dish in
                    NavigationLink { DishView(dish: dish) } label: { row(dish) }
                }
            }
        }
        .listSectionSpacing(14)
        .tabBarClearance()
        .searchable(text: $query, prompt: "Zoek gerecht of label")
        .navigationTitle("Kookboek")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nieuw gerecht", systemImage: "plus") { showAdd = true }
            }
        }
        .sheet(isPresented: $showAdd) { AddDishSheet() }
    }

    private func chip(_ title: String, _ value: String?) -> some View {
        let on = filter == value
        return Button(title) { filter = value }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? Color.green : Color(.tertiarySystemFill), in: Capsule())
            .buttonStyle(.plain)
    }

    private func row(_ dish: Dish) -> some View {
        HStack(spacing: 12) {
            DishImage(dish: dish, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(dish.name).font(.headline).lineLimit(2)
                if dish.rating > 0 {
                    Text(String(repeating: "★", count: dish.rating)).font(.caption).foregroundStyle(.yellow)
                }
                Text(subtitle(dish)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ dish: Dish) -> String {
        guard let last = lastCooked[dish.syncID] else { return "nog te proberen" }
        let n = cookCount[dish.syncID] ?? 1
        return "laatst \(last.formatted(.dateTime.day().month(.abbreviated)))" + (n > 1 ? " · \(n)×" : "")
    }
}

// MARK: - Nieuw gerecht

struct AddDishSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]
    @State private var link = ""
    @State private var name = ""
    @State private var imported: ImportedRecipe?
    @State private var chosenLabels: Set<String> = []
    @State private var loading = false
    @State private var failed = false
    @FocusState private var focused: Bool

    private var clipboardLink: String? {
        // Alleen kijken of er een URL op staat; de inhoud lezen vraagt de plak-toestemming
        // en dat doen we pas als je op de knop tikt.
        UIPasteboard.general.hasURLs ? UIPasteboard.general.url?.absoluteString : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Link naar het recept", text: $link)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { Task { await importLink() } }
                        if loading { ProgressView() } else if !link.isEmpty {
                            Button("Ophalen") { Task { await importLink() } }.buttonStyle(.borderless)
                        }
                    }
                    if link.isEmpty, let clip = clipboardLink {
                        Button("Plak link", systemImage: "doc.on.clipboard") {
                            link = clip
                            Task { await importLink() }
                        }
                    }
                    if failed {
                        Label("Kon het recept niet ophalen. Vul de naam zelf in.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Van de meeste receptsites komen naam, foto, ingrediënten en porties vanzelf mee. Zonder link vul je alleen een naam in.")
                }

                Section {
                    TextField("Naam", text: $name).focused($focused)
                    if let imported {
                        if !imported.ingredients.isEmpty {
                            Text("\(imported.ingredients.count) ingrediënten" + (imported.steps.isEmpty ? "" : " · \(imported.steps.count) stappen") + (imported.servings > 0 ? " · \(imported.servings.formatted()) porties" : "")
                                 + (imported.minutes > 0 ? " · \(imported.minutes) min" : ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !imported.labelSuggestions.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(imported.labelSuggestions, id: \.self) { l in
                                    let on = chosenLabels.contains(l)
                                    Button(l) { if on { chosenLabels.remove(l) } else { chosenLabels.insert(l) } }
                                        .font(.subheadline)
                                        .foregroundStyle(on ? .white : .primary)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(on ? Color.green : Color(.tertiarySystemFill), in: Capsule())
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .tint(.green)
            .navigationTitle("Nieuw gerecht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Toevoegen") { add() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func importLink() async {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { failed = true; return }
        loading = true; failed = false
        imported = await RecipeImport.fetch(url)
        loading = false
        if let imported { name = imported.name } else { failed = true; focused = true }
    }

    private func add() {
        let dish = Dish(name: name.trimmingCharacters(in: .whitespaces))
        dish.url = link.trimmingCharacters(in: .whitespaces)
        dish.labels = chosenLabels.sorted()
        if let imported {
            dish.imageURL = imported.imageURL
            dish.servings = imported.servings
            dish.minutes = imported.minutes
            dish.siteProtein = imported.protein
            dish.siteKcal = imported.kcal
            dish.steps = imported.steps
            dish.ingredients = imported.ingredients.map { line in
                var i = DishIngredient(text: line)
                i.productID = autoMatch(i.searchTerm)?.syncID
                return i
            }
        }
        context.insert(dish)
        dismiss()
    }

    /// Alleen je eigen producten, en alleen als de naam er echt op lijkt (vooraan of op een
    /// woordgrens). Een merkproduct uit OpenFoodFacts gokken is erger dan niet koppelen.
    private func autoMatch(_ term: String) -> FoodProduct? {
        guard !term.isEmpty else { return nil }
        return products.map { ($0, foodMatchScore($0.name, query: term)) }
            .filter { $0.1 >= 2 }
            .max { $0.1 < $1.1 }?.0
    }
}

// MARK: - Gerecht

struct DishView: View {
    @Bindable var dish: Dish
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]
    @Query private var allCooks: [Cook]
    @State private var photoPick: PhotosPickerItem?
    @State private var photoVersion = 0
    @State private var editing: Cook?
    @State private var linking: DishIngredient?
    @State private var newLabel = ""
    @State private var newIngredient = ""
    @State private var newStep = ""
    @State private var confirmDelete = false

    private var cooks: [Cook] { allCooks.filter { $0.dishID == dish.syncID }.sorted { $0.date > $1.date } }
    private var macros: Dish.Macros? { dish.macros(products: products) }
    private var linkedCount: Int { dish.ingredients.filter { $0.productID != nil }.count }

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $photoPick, matching: .images) {
                    DishImage(dish: dish, size: 160)
                        .frame(maxWidth: .infinity)
                        .id(photoVersion)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .contextMenu {
                    if DishPhoto.existing(dish) != nil {
                        Button("Verwijder eigen foto", systemImage: "trash", role: .destructive) {
                            DishPhoto.remove(dish); photoVersion += 1
                        }
                    }
                }
                .accessibilityLabel("Eigen foto kiezen")
            }

            Section {
                TextField("Naam", text: $dish.name).font(.headline)
                Stars(rating: $dish.rating)
                labelsRow
            }

            Section {
                HStack(spacing: 10) {
                    Button { startCook(date: .now) } label: {
                        Text("Maak nu").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    Button { startCook(date: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) } label: {
                        Label("Plan", systemImage: "calendar")
                    }
                    .buttonStyle(.bordered)
                }
                .buttonBorderShape(.roundedRectangle(radius: BuiltRadius.medium))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let url = URL(string: dish.url), !dish.url.isEmpty {
                    Link(destination: url) { Label("Bron", systemImage: "safari") }
                }
            }

            Section {
                LabeledContent("Porties") {
                    TextField("4", value: $dish.servings, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                }
                if dish.minutes > 0 { LabeledContent("Bereiding", value: "\(dish.minutes) min") }
                if let macros {
                    LabeledContent("Per portie", value: "\(macros.protein) g eiwit · \(macros.kcal) kcal")
                    if !macros.complete {
                        Text("Macro's onvolledig: \(linkedCount) van \(dish.ingredients.count) ingrediënten gekoppeld.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Ingrediënten") {
                ForEach(dish.ingredients) { i in
                    Button { linking = i } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.text).foregroundStyle(Color.primary)
                            if let p = i.productID.flatMap({ id in products.first { $0.syncID == id } }) {
                                Label(p.name, systemImage: "link").font(.caption).foregroundStyle(.green)
                            } else {
                                Text("Tik om een product te koppelen").font(.caption).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .onDelete { dish.ingredients.remove(atOffsets: $0) }
                TextField("Ingrediënt toevoegen", text: $newIngredient)
                    .onSubmit {
                        let t = newIngredient.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        dish.ingredients.append(DishIngredient(text: t)); newIngredient = ""
                    }
            }

            Section("Bereiding") {
                ForEach(Array(dish.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.subheadline.bold().monospacedDigit()).foregroundStyle(.green)
                        Text(step)
                    }
                }
                .onDelete { dish.steps.remove(atOffsets: $0) }
                TextField("Stap toevoegen", text: $newStep, axis: .vertical)
                    .onSubmit {
                        let t = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        dish.steps.append(t); newStep = ""
                    }
            }

            Section("Kookbeurten") {
                if cooks.isEmpty {
                    Text("Nog niet gemaakt.").foregroundStyle(.secondary)
                }
                ForEach(cooks) { cook in
                    Button { editing = cook } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: cook.done ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(cook.done ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cook.date.formatted(.dateTime.day().month(.wide).year()))
                                    .font(.subheadline.bold()).foregroundStyle(Color.primary)
                                if !cook.note.isEmpty {
                                    Text(cook.note).font(.subheadline).foregroundStyle(Color.secondary)
                                } else if !cook.done {
                                    Text("gepland").font(.caption).foregroundStyle(Color.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Weg", systemImage: "trash", role: .destructive) { context.deleteSynced(cook) }
                    }
                }
            }
        }
        .tabBarClearance()
        .navigationTitle(dish.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Verwijder gerecht", systemImage: "trash", role: .destructive) {
                        if cooks.isEmpty { deleteDish() } else { confirmDelete = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Meer")
            }
        }
        .confirmationDialog("Gerecht en \(cooks.count) kookbeurten verwijderen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Verwijder", role: .destructive) { deleteDish() }
        }
        .sheet(item: $editing) { cook in CookSheet(cook: cook, dish: dish, macros: macros) }
        .sheet(item: $linking) { ingredient in
            IngredientLinkSheet(ingredient: ingredient) { updated in
                if let idx = dish.ingredients.firstIndex(where: { $0.id == updated.id }) { dish.ingredients[idx] = updated }
            }
        }
        .onChange(of: photoPick) {
            guard let photoPick else { return }
            Task {
                if let data = try? await photoPick.loadTransferable(type: Data.self) {
                    try? DishPhoto.save(data, for: dish)
                    photoVersion += 1
                }
                self.photoPick = nil
            }
        }
    }

    private var labelsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(dish.labels, id: \.self) { l in
                    Text(l)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.builtTint(.green), in: Capsule())
                        .contextMenu { Button("Verwijder label", role: .destructive) { dish.labels.removeAll { $0 == l } } }
                }
                TextField("+ label", text: $newLabel)
                    .font(.caption)
                    .frame(minWidth: 70)
                    .onSubmit {
                        let l = newLabel.trimmingCharacters(in: .whitespaces).lowercased()
                        if !l.isEmpty, !dish.labels.contains(l) { dish.labels.append(l) }
                        newLabel = ""
                    }
            }
        }
    }

    private func startCook(date: Date) {
        let cook = Cook(dishID: dish.syncID, date: date)
        context.insert(cook)
        editing = cook
    }

    private func deleteDish() {
        for c in cooks { context.deleteSynced(c) }
        DishPhoto.remove(dish)
        context.deleteSynced(dish)
        dismiss()
    }
}

// MARK: - Kookbeurt

struct CookSheet: View {
    @Bindable var cook: Cook
    let dish: Dish
    let macros: Dish.Macros?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var logPortions = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Dag", selection: $cook.date, displayedComponents: .date)
                }
                // Het recept staat hier, in de app: je kookt ervan en tikt onderaan je notitie.
                if !dish.ingredients.isEmpty {
                    Section("Ingrediënten" + (dish.servings > 0 ? " · \(dish.servings.formatted()) porties" : "")) {
                        ForEach(dish.ingredients) { Text($0.text) }
                    }
                }
                if !dish.steps.isEmpty {
                    Section("Bereiding") {
                        ForEach(Array(dish.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)").font(.subheadline.bold().monospacedDigit()).foregroundStyle(.green)
                                Text(step)
                            }
                        }
                    }
                }
                Section("Notities voor de volgende keer") {
                    TextEditor(text: $cook.note)
                        .frame(minHeight: 100)
                }
                if !cook.done {
                    Section {
                        Button { finish() } label: {
                            Text("Klaar").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                        if let macros, macros.kcal > 0 || macros.protein > 0 {
                            Stepper(value: $logPortions, in: 0...6, step: 1) {
                                LabeledContent("Loggen bij diner",
                                               value: logPortions == 0 ? "niet" : "\(logPortions.formatted()) portie\(logPortions == 1 ? "" : "s")")
                            }
                        }
                    } footer: {
                        if let macros, macros.kcal > 0 || macros.protein > 0 {
                            Text("Per portie \(macros.protein) g eiwit · \(macros.kcal) kcal.")
                        }
                    }
                }
            }
            .tint(.green)
            .navigationTitle(dish.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Sluit") { dismiss() } } }
        }
    }

    private func finish() {
        cook.done = true
        if logPortions > 0, let macros {
            let stamp = timestamp(on: cook.date, hour: 18)
            context.insert(ProteinEntry(date: stamp, grams: Int((Double(macros.protein) * logPortions).rounded()),
                                        label: dish.name, kcal: Int((Double(macros.kcal) * logPortions).rounded()),
                                        meal: "dinner"))
        }
        dismiss()
    }
}

// MARK: - Ingrediënt koppelen

struct IngredientLinkSheet: View {
    @State var ingredient: DishIngredient
    let save: (DishIngredient) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var products: [FoodProduct]
    @State private var query = ""
    @State private var results: [OFF.Product] = []
    @State private var searching = false

    private var own: [FoodProduct] {
        guard !query.isEmpty else { return [] }
        return products.map { ($0, foodMatchScore($0.name, query: query)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
    }
    private var ownIDs: Set<String> { Set(products.map { $0.barcode.isEmpty ? $0.name : $0.barcode }) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Hoeveelheid", value: $ingredient.amount, format: .number)
                            .keyboardType(.decimalPad)
                        Picker("Eenheid", selection: $ingredient.unit) {
                            Text("g").tag("g"); Text("ml").tag("ml"); Text("stuk").tag("stuk")
                        }
                        .pickerStyle(.segmented).frame(width: 150)
                    }
                    if let p = ingredient.productID.flatMap({ id in products.first { $0.syncID == id } }) {
                        LabeledContent("Gekoppeld aan", value: p.name)
                        Button("Ontkoppel", role: .destructive) { ingredient.productID = nil }
                    }
                } header: {
                    Text(ingredient.text)
                }
                Section("Product") {
                    TextField("Zoek product", text: $query)
                        .onSubmit { search() }
                    ForEach(own) { p in
                        Button { ingredient.productID = p.syncID } label: {
                            HStack {
                                FoodThumb(url: p.imageURL, size: 32, photo: p.localPhoto)
                                Text(p.name).foregroundStyle(Color.primary)
                                Spacer()
                                if ingredient.productID == p.syncID { Image(systemName: "checkmark").foregroundStyle(.green) }
                            }
                        }
                    }
                    if searching { ProgressView() }
                    ForEach(results.filter { !ownIDs.contains($0.id) }) { r in
                        Button { link(r) } label: {
                            HStack {
                                FoodThumb(url: r.imageURL, size: 32)
                                VStack(alignment: .leading) {
                                    Text(r.name).foregroundStyle(Color.primary)
                                    if !r.brand.isEmpty { Text(r.brand).font(.caption).foregroundStyle(Color.secondary) }
                                }
                            }
                        }
                    }
                    if !searching, results.isEmpty, !query.isEmpty {
                        Button("Zoek op OpenFoodFacts", systemImage: "magnifyingglass") { search() }
                    }
                }
            }
            .tint(.green)
            .navigationTitle("Koppelen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Bewaar") { save(ingredient); dismiss() } }
            }
            .onAppear { query = ingredient.searchTerm }
        }
    }

    private func search() {
        let q = query
        searching = true
        Task {
            let found = await OFF.search(q)
            guard q == query else { return }
            results = found ?? []
            searching = false
        }
    }

    /// Zelfde regel als bij het loggen: een OFF-product wordt een eigen product zodra je
    /// 'm ergens aan hangt.
    private func link(_ r: OFF.Product) {
        let product: FoodProduct
        if let existing = products.first(where: { !r.barcode.isEmpty && $0.barcode == r.barcode }) {
            product = existing
        } else {
            product = FoodProduct(name: r.name, brand: r.brand, barcode: r.barcode,
                                  protein100: r.protein100, kcal100: r.kcal100, carbs100: r.carbs100, fat100: r.fat100)
            product.imageURL = r.imageURL
            product.servingGrams = r.servingGrams
            product.unit = r.unit.rawValue
            context.insert(product)
        }
        ingredient.productID = product.syncID
    }
}
