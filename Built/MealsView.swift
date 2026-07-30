import SwiftUI
import SwiftData

let mealOrder = ["breakfast", "lunch", "dinner", "snack"]
let mealNames = ["breakfast": "Ontbijt", "lunch": "Lunch", "dinner": "Diner", "snack": "Snacks"]

// Eiwit loggen, gestructureerd per maaltijd (Lifesum/MyFitnessPal-patroon).
// Tik = 1 portie; ingedrukt houden = porties of aanpassen; tik op gelogd item = bewerken.
struct ProteinLogSheet: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var proteins: [ProteinEntry]
    @Query(sort: \Meal.createdAt) private var meals: [Meal]

    @State private var editingEntry: ProteinEntry?
    @State private var showCustom = false
    @State private var customPrefill: QuickAdd?

    struct QuickAdd: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        let grams: Int
        let kcal: Int
        let favorite: Bool
    }

    private var cal: Calendar { .current }
    private var todayEntries: [ProteinEntry] {
        proteins.filter { cal.isDateInToday($0.date) }.sorted { $0.date < $1.date }
    }
    private var todayProtein: Int { todayEntries.map(\.grams).reduce(0, +) }
    private var todayKcal: Int { todayEntries.map(\.kcal).reduce(0, +) }

    private var yesterdayEntries: [ProteinEntry] {
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: .now) else { return [] }
        return proteins.filter { dayKey($0.date) == dayKey(yesterday) }
    }

    private var quickAdds: [QuickAdd] {
        var out = meals.filter { $0.proteinPerServing > 0 }
            .sorted { ($0.favorite ? 0 : 1, $0.createdAt) < (($1.favorite ? 0 : 1), $1.createdAt) }
            .map { QuickAdd(key: "meal-\($0.name)", label: $0.name,
                            grams: $0.proteinPerServing, kcal: $0.kcalPerServing, favorite: $0.favorite) }
        for s in proteins.suggestions(limit: 8) where !out.contains(where: { $0.label == s.label }) {
            out.append(QuickAdd(key: s.key, label: s.label, grams: s.grams, kcal: s.kcal, favorite: false))
        }
        return Array(out.prefix(8))
    }

    private func entries(for meal: String) -> [ProteinEntry] {
        todayEntries.filter { $0.mealKey == meal }
    }

    private func mealTotal(_ meal: String) -> Int {
        entries(for: meal).map(\.grams).reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Vandaag", value: "\(todayProtein) / \(profile.proteinTarget) g\(todayKcal > 0 ? " · \(todayKcal) kcal" : "")")
                    HStack(spacing: 0) {
                        ForEach(mealOrder, id: \.self) { meal in
                            VStack(spacing: 2) {
                                Text("\(mealTotal(meal))")
                                    .font(.footnote.bold().monospacedDigit())
                                Text(mealNames[meal] ?? meal)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    if !yesterdayEntries.isEmpty {
                        Button {
                            repeatYesterday()
                        } label: {
                            Label("Herhaal gisteren (\(yesterdayEntries.map(\.grams).reduce(0, +)) g)",
                                  systemImage: "arrow.uturn.backward")
                        }
                    }
                    ForEach(quickAdds) { item in
                        Button {
                            log(item)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                Text(item.label).foregroundStyle(.primary)
                                if item.favorite {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                                Spacer()
                                Text("\(item.grams) g").foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("½ portie (\(Int((Double(item.grams) * 0.5).rounded())) g)") { log(item, multiplier: 0.5) }
                            Button("1½ portie (\(Int((Double(item.grams) * 1.5).rounded())) g)") { log(item, multiplier: 1.5) }
                            Button("2 porties (\(item.grams * 2) g)") { log(item, multiplier: 2) }
                            Divider()
                            Button("Aanpassen…", systemImage: "slider.horizontal.3") {
                                customPrefill = item
                                showCustom = true
                            }
                        }
                    }
                    Button {
                        customPrefill = nil
                        showCustom = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            Text("Eigen maaltijd…").foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Snel toevoegen")
                } footer: {
                    Text("Tik = 1 portie · houd ingedrukt voor porties of aanpassen.")
                }

                ForEach(mealOrder, id: \.self) { meal in
                    let list = entries(for: meal)
                    if !list.isEmpty {
                        Section("\(mealNames[meal] ?? meal) — \(mealTotal(meal)) g") {
                            ForEach(list) { entry in
                                Button {
                                    editingEntry = entry
                                } label: {
                                    LabeledContent {
                                        Text("\(entry.grams) g\(entry.kcal > 0 ? " · \(entry.kcal) kcal" : "")")
                                    } label: {
                                        Text(entry.label).foregroundStyle(.primary)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                for i in offsets { context.delete(list[i]) }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink { MealsView() } label: {
                        Label("Maaltijden & recepten", systemImage: "fork.knife")
                    }
                }
            }
            .navigationTitle("Eiwit loggen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar") { dismiss() }
                }
            }
            .sensoryFeedback(.increase, trigger: todayProtein)
            .sheet(item: $editingEntry) { entry in
                ProteinEntrySheet(entry: entry)
            }
            .sheet(isPresented: $showCustom) {
                ProteinEntrySheet(prefill: customPrefill)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func log(_ item: QuickAdd, multiplier: Double = 1) {
        context.insert(ProteinEntry(grams: Int((Double(item.grams) * multiplier).rounded()),
                                    label: item.label,
                                    kcal: Int((Double(item.kcal) * multiplier).rounded()),
                                    meal: ProteinEntry.guessMeal()))
    }

    private func repeatYesterday() {
        for entry in yesterdayEntries {
            // Niet in de toekomst plaatsen: een item van gisteravond wordt anders "vanavond".
            let newDate = min(cal.date(byAdding: .day, value: 1, to: entry.date) ?? .now, .now)
            context.insert(ProteinEntry(date: newDate, grams: entry.grams, label: entry.label,
                                        kcal: entry.kcal, meal: entry.meal))
        }
    }
}

/// Eén sheet voor alles: eigen maaltijd toevoegen, een suggestie aanpassen,
/// of een gelogd item bewerken.
struct ProteinEntrySheet: View {
    var entry: ProteinEntry?
    var prefill: ProteinLogSheet.QuickAdd?
    var entryDate: Date = .now

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var grams = 0
    @State private var kcal = 0
    @State private var carbs = 0
    @State private var fat = 0
    @State private var meal = ProteinEntry.guessMeal()
    @State private var saveAsMeal = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Wat (bijv. Kwark)", text: $label)
                LabeledContent("Eiwit (g)") {
                    TextField("g", value: $grams, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Kcal") {
                    TextField("kcal", value: $kcal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Koolhydraten (g)") {
                    TextField("g", value: $carbs, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Vet (g)") {
                    TextField("g", value: $fat, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Maaltijd", selection: $meal) {
                    ForEach(mealOrder, id: \.self) { m in
                        Text(mealNames[m] ?? m).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                if entry == nil {
                    Toggle("Bewaar als vaste maaltijd", isOn: $saveAsMeal)
                }
            }
            .navigationTitle(entry == nil ? "Eiwit toevoegen" : "Bewerk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opslaan") { save() }
                        .disabled(grams <= 0)
                }
            }
        }
        .presentationDetents([.height(460)])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let entry {
                label = entry.label
                grams = entry.grams
                kcal = entry.kcal
                carbs = entry.carbs
                fat = entry.fat
                meal = entry.mealKey
            } else if let prefill {
                meal = ProteinEntry.guessMeal(for: entryDate)
                label = prefill.label
                grams = prefill.grams
                kcal = prefill.kcal
            }
        }
    }

    private func save() {
        let cleanLabel = label.trimmingCharacters(in: .whitespaces)
        if let entry {
            entry.label = cleanLabel.isEmpty ? "Eigen maaltijd" : cleanLabel
            entry.grams = grams
            entry.kcal = kcal
            entry.carbs = carbs
            entry.fat = fat
            entry.meal = meal
        } else {
            context.insert(ProteinEntry(date: entryDate, grams: grams,
                                        label: cleanLabel.isEmpty ? "Eigen maaltijd" : cleanLabel,
                                        kcal: kcal, carbs: carbs, fat: fat, meal: meal))
            if saveAsMeal, !cleanLabel.isEmpty {
                context.insert(Meal(name: cleanLabel, protein: grams, kcal: kcal))
            }
        }
        dismiss()
    }
}

struct MealsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Meal.createdAt) private var meals: [Meal]
    @State private var showAdd = false
    @State private var nameInput = ""

    var body: some View {
        List {
            Section {
                if meals.isEmpty {
                    ContentUnavailableView("Nog geen maaltijden", systemImage: "fork.knife",
                                           description: Text("Voeg je vaste maaltijden of recepten toe, dan log je ze voortaan met één tik."))
                }
                ForEach(meals) { m in
                    NavigationLink {
                        MealEditorView(meal: m)
                    } label: {
                        HStack(spacing: 8) {
                            if m.favorite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                Text("\(m.proteinPerServing) g eiwit\(m.kcalPerServing > 0 ? " · \(m.kcalPerServing) kcal" : "")\(m.ingredients.isEmpty ? "" : " · \(m.ingredients.count) ingrediënten") per portie")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            m.favorite.toggle()
                        } label: {
                            Label("Favoriet", systemImage: m.favorite ? "star.slash" : "star.fill")
                        }
                        .tint(.yellow)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(meals[i]) }
                }
                Button { showAdd = true } label: {
                    Label("Nieuwe maaltijd of recept", systemImage: "plus")
                }
            } footer: {
                Text("Swipe naar rechts voor favoriet (altijd bovenaan je quick-add lijst). Tik op een maaltijd om er een recept met ingrediënten en porties van te maken.")
            }
        }
        .navigationTitle("Maaltijden & recepten")
        .alert("Nieuwe maaltijd", isPresented: $showAdd) {
            TextField("Naam (bijv. Kip & rijst)", text: $nameInput)
            Button("Aanmaken") {
                let name = nameInput.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { context.insert(Meal(name: name, protein: 0, kcal: 0)) }
                nameInput = ""
            }
            Button("Annuleer", role: .cancel) { nameInput = "" }
        } message: {
            Text("Vul daarna de voedingswaarde in — direct, of via ingrediënten.")
        }
    }
}

struct MealEditorView: View {
    @Bindable var meal: Meal
    @State private var showAddIngredient = false
    @State private var nameInput = ""
    @State private var proteinInput = ""
    @State private var kcalInput = ""

    var body: some View {
        List {
            Section("Per portie") {
                LabeledContent("Eiwit", value: "\(meal.proteinPerServing) g")
                LabeledContent("Kcal", value: meal.kcalPerServing > 0 ? "\(meal.kcalPerServing)" : "—")
                Toggle("Favoriet ⭐️", isOn: $meal.favorite)
                if !meal.ingredients.isEmpty {
                    LabeledContent("Totaal recept", value: "\(meal.totalProtein) g · \(meal.totalKcal) kcal")
                    Stepper("Porties: \(meal.servings.kgText)", value: $meal.servings, in: 0.5...20, step: 0.5)
                }
            }

            if meal.ingredients.isEmpty {
                Section {
                    LabeledContent("Eiwit (g)") {
                        TextField("g", value: $meal.protein, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Kcal") {
                        TextField("kcal", value: $meal.kcal, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Voedingswaarde")
                } footer: {
                    Text("Of voeg ingrediënten toe — dan rekent de app het per portie uit.")
                }
            }

            Section("Ingrediënten") {
                ForEach(meal.ingredients) { ing in
                    LabeledContent(ing.name, value: "\(ing.protein) g\(ing.kcal > 0 ? " · \(ing.kcal) kcal" : "")")
                }
                .onDelete { meal.ingredients.remove(atOffsets: $0) }
                Button { showAddIngredient = true } label: {
                    Label("Ingrediënt toevoegen", systemImage: "plus")
                }
            }
        }
        .navigationTitle($meal.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Ingrediënt toevoegen", isPresented: $showAddIngredient) {
            TextField("Naam (bijv. 200 g kipfilet)", text: $nameInput)
            TextField("Eiwit (g)", text: $proteinInput).keyboardType(.numberPad)
            TextField("Kcal (optioneel)", text: $kcalInput).keyboardType(.numberPad)
            Button("Toevoegen") {
                let name = nameInput.trimmingCharacters(in: .whitespaces)
                if let g = Int(proteinInput), !name.isEmpty {
                    meal.ingredients.append(Ingredient(name: name, protein: g, kcal: Int(kcalInput) ?? 0))
                }
                nameInput = ""; proteinInput = ""; kcalInput = ""
            }
            Button("Annuleer", role: .cancel) { nameInput = ""; proteinInput = ""; kcalInput = "" }
        }
    }
}
