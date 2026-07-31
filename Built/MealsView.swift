import SwiftUI
import SwiftData

/// Maaltijdmómenten. Let op: het `Meal`-model hiernaast is iets anders — dat is een
/// recept (in de UI "Recepten"). Zelfde woord, twee betekenissen; vandaar "slot".
let mealSlots = ["breakfast", "lunch", "dinner", "snack"]
let mealSlotNames = ["breakfast": "Ontbijt", "lunch": "Lunch", "dinner": "Diner", "snack": "Snacks"]


/// Eén sheet voor alles: eigen maaltijd toevoegen, een suggestie aanpassen,
/// of een gelogd item bewerken.
struct ProteinEntrySheet: View {
    var entry: ProteinEntry?
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
    /// Hoeveelheid in de eenheid van de invoer; 0 = geen portie bekend.
    @State private var amount = 0

    /// Met een bekende portie bewerk je de hoeveelheid en schalen de macro's mee.
    /// Zonder (oudere invoer) blijft het handmatig — dan is er niets om op te schalen.
    private var per100: (protein: Double, kcal: Double, carbs: Double, fat: Double)? { entry?.per100 }

    private func scale(_ v: Double) -> Int { Int((v * Double(amount) / 100).rounded()) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Wat (bijv. Kwark)", text: $label)
                if let p = per100 {
                    let unit = entry?.foodUnit ?? .gram
                    Section {
                        HStack(spacing: 10) {
                            Button { amount = max(amount - (unit == .milliliter ? 50 : 10), 0) } label: {
                                Image(systemName: "minus").frame(width: 30, height: 30)
                            }
                            .buttonStyle(.bordered).disabled(amount <= 0)
                            .accessibilityLabel("Minder")
                            .accessibilityValue("\(amount) \(unit.label)")
                            TextField("100", value: $amount, format: .number)
                                .keyboardType(.numberPad)
                                .font(.title3.bold().monospacedDigit())
                                .multilineTextAlignment(.center)
                                .frame(width: 64)
                                .accessibilityLabel("Hoeveelheid")
                                .accessibilityValue("\(amount) \(unit.label)")
                            Text(unit.label).foregroundStyle(.secondary)
                            Button { amount += (unit == .milliliter ? 50 : 10) } label: {
                                Image(systemName: "plus").frame(width: 30, height: 30)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Meer")
                            .accessibilityValue("\(amount) \(unit.label)")
                            Spacer()
                        }
                        Text("\(scale(p.protein)) g eiwit · \(scale(p.kcal)) kcal · \(scale(p.carbs)) g koolh. · \(scale(p.fat)) g vet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.2), value: amount)
                    } header: {
                        Text("Hoeveelheid")
                    }
                } else {
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
                }
                Picker("Maaltijd", selection: $meal) {
                    ForEach(mealSlots, id: \.self) { m in
                        Text(mealSlotNames[m] ?? m).tag(m)
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
                        .disabled(per100 == nil ? grams <= 0 : amount <= 0)
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
                amount = Int(entry.amount.rounded())
            }
        }
    }

    private func save() {
        let cleanLabel = label.trimmingCharacters(in: .whitespaces)
        if let entry {
            entry.label = cleanLabel.isEmpty ? "Eigen maaltijd" : cleanLabel
            if entry.per100 != nil {
                entry.rescale(to: Double(amount)) // macro's volgen de portie
            } else {
                entry.grams = grams
                entry.kcal = kcal
                entry.carbs = carbs
                entry.fat = fat
            }
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
                                    .accessibilityLabel("Favoriet")
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
