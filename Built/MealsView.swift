import SwiftUI
import SwiftData

struct ProteinLogSheet: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var proteins: [ProteinEntry]
    @Query(sort: \Meal.createdAt) private var meals: [Meal]

    @State private var showCustomAlert = false
    @State private var labelInput = ""
    @State private var proteinInput = ""
    @State private var kcalInput = ""

    private var cal: Calendar { .current }
    private var todayEntries: [ProteinEntry] {
        proteins.filter { cal.isDateInToday($0.date) }.sorted { $0.date < $1.date }
    }
    private var todayProtein: Int { todayEntries.map(\.grams).reduce(0, +) }
    private var todayKcal: Int { todayEntries.map(\.kcal).reduce(0, +) }

    private var quickAdds: [(key: String, label: String, grams: Int, kcal: Int)] {
        var out = meals.filter { $0.proteinPerServing > 0 }
            .map { (key: "meal-\($0.name)", label: $0.name, grams: $0.proteinPerServing, kcal: $0.kcalPerServing) }
        for s in proteins.suggestions(limit: 8) where !out.contains(where: { $0.label == s.label }) {
            out.append(s)
        }
        return out.prefix(8).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Vandaag", value: "\(todayProtein) / \(profile.proteinTarget) g\(todayKcal > 0 ? " · \(todayKcal) kcal" : "")")
                }
                Section("Snel toevoegen") {
                    ForEach(quickAdds, id: \.key) { s in
                        Button {
                            context.insert(ProteinEntry(grams: s.grams, label: s.label, kcal: s.kcal))
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                Text(s.label).foregroundStyle(.primary)
                                Spacer()
                                Text("\(s.grams) g").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { showCustomAlert = true } label: {
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            Text("Eigen maaltijd…").foregroundStyle(.primary)
                        }
                    }
                }
                if !todayEntries.isEmpty {
                    Section("Vandaag gelogd") {
                        ForEach(todayEntries) { e in
                            LabeledContent(e.label, value: "\(e.grams) g\(e.kcal > 0 ? " · \(e.kcal) kcal" : "")")
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(todayEntries[i]) }
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
            .alert("Eigen maaltijd", isPresented: $showCustomAlert) {
                TextField("Wat (bijv. Kwark)", text: $labelInput)
                TextField("Eiwit (g)", text: $proteinInput).keyboardType(.numberPad)
                TextField("Kcal (optioneel)", text: $kcalInput).keyboardType(.numberPad)
                Button("Toevoegen") {
                    if let g = Int(proteinInput), g > 0 {
                        let label = labelInput.trimmingCharacters(in: .whitespaces)
                        context.insert(ProteinEntry(grams: g, label: label.isEmpty ? "Eigen maaltijd" : label, kcal: Int(kcalInput) ?? 0))
                    }
                    labelInput = ""; proteinInput = ""; kcalInput = ""
                }
                Button("Annuleer", role: .cancel) { labelInput = ""; proteinInput = ""; kcalInput = "" }
            }
        }
        .presentationDetents([.medium, .large])
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
                ForEach(meals) { m in
                    NavigationLink {
                        MealEditorView(meal: m)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name)
                            Text("\(m.proteinPerServing) g eiwit\(m.kcalPerServing > 0 ? " · \(m.kcalPerServing) kcal" : "")\(m.ingredients.isEmpty ? "" : " · \(m.ingredients.count) ingrediënten") per portie")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(meals[i]) }
                }
                Button { showAdd = true } label: {
                    Label("Nieuwe maaltijd of recept", systemImage: "plus")
                }
            } footer: {
                Text("Vaste gerechten staan bovenaan je quick-add lijst. Tik op een maaltijd om er een recept met ingrediënten en porties van te maken.")
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
