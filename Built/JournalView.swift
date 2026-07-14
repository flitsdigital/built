import SwiftUI
import SwiftData

struct JournalView: View {
    let profile: Profile
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]

    private var cal: Calendar { .current }

    private var days: [Date] {
        var all = Set<Date>()
        for w in weights { all.insert(cal.startOfDay(for: w.date)) }
        for p in proteins { all.insert(cal.startOfDay(for: p.date)) }
        for s in sets { all.insert(cal.startOfDay(for: s.date)) }
        for h in habits { all.insert(cal.startOfDay(for: h.date)) }
        all.insert(cal.startOfDay(for: .now))
        return all.sorted(by: >).prefix(365).map { $0 }
    }

    private func summary(_ day: Date) -> String {
        var parts: [String] = []
        if sets.contains(where: { cal.isDate($0.date, inSameDayAs: day) }) { parts.append("Training") }
        let protein = proteins.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.grams).reduce(0, +)
        if protein > 0 { parts.append("\(protein) g eiwit") }
        if let w = weights.last(where: { cal.isDate($0.date, inSameDayAs: day) }) { parts.append("\(w.kg.kgText) kg") }
        return parts.isEmpty ? "Niets gelogd" : parts.joined(separator: " · ")
    }

    private func note(_ day: Date) -> String? {
        let n = habits.first { cal.isDate($0.date, inSameDayAs: day) }?.note ?? ""
        return n.isEmpty ? nil : n
    }

    var body: some View {
        List {
            ForEach(days, id: \.self) { day in
                NavigationLink {
                    DayDetailView(day: day, profile: profile)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.headline)
                        Text(summary(day))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let note = note(day) {
                            Text(note)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .listRowBackground(Color.cleanCard)
        }
        .cleanScreen()
        .navigationTitle("Logboek")
    }
}

struct DayDetailView: View {
    let day: Date
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var allWeights: [WeightEntry]
    @Query(sort: \ProteinEntry.date) private var allProteins: [ProteinEntry]
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allHabits: [DayHabits]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query private var habitLogs: [HabitLog]

    @State private var showProteinAlert = false
    @State private var labelInput = ""
    @State private var gramsInput = ""
    @State private var kcalInput = ""
    @State private var showWeightAlert = false
    @State private var weightInput = ""

    private var cal: Calendar { .current }
    private var weights: [WeightEntry] { allWeights.filter { cal.isDate($0.date, inSameDayAs: day) } }
    private var proteins: [ProteinEntry] { allProteins.filter { cal.isDate($0.date, inSameDayAs: day) } }
    private var daySets: [SetEntry] { allSets.filter { cal.isDate($0.date, inSameDayAs: day) } }
    private var habitsRecord: DayHabits? { allHabits.first { cal.isDate($0.date, inSameDayAs: day) } }

    private var setsByExercise: [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets where !names.contains(s.exercise) { names.append(s.exercise) }
        return names.map { n in (n, daySets.filter { $0.exercise == n }) }
    }

    private var noon: Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day }

    private func record() -> DayHabits {
        if let h = habitsRecord { return h }
        let h = DayHabits(date: noon)
        context.insert(h)
        return h
    }

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<DayHabits, T>, default d: T) -> Binding<T> {
        Binding(get: { habitsRecord?[keyPath: keyPath] ?? d },
                set: { record()[keyPath: keyPath] = $0 })
    }

    private func customBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { habitLogs.contains { $0.name == name && cal.isDate($0.date, inSameDayAs: day) } },
            set: { on in
                if on {
                    context.insert(HabitLog(name: name, date: noon))
                } else if let log = habitLogs.first(where: { $0.name == name && cal.isDate($0.date, inSameDayAs: day) }) {
                    context.delete(log)
                }
            })
    }

    private func sleepTime(_ keyPath: ReferenceWritableKeyPath<DayHabits, Date?>, defaultHour: Int) -> Binding<Date> {
        Binding(
            get: {
                habitsRecord?[keyPath: keyPath]
                    ?? cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) ?? day
            },
            set: { newValue in
                let r = record()
                r[keyPath: keyPath] = newValue
                if let h = r.sleepHours { r.sleptEnough = h >= 8 } // consistent met het "8 uur slaap"-label
            })
    }

    var body: some View {
        List {
            Section("Habits") {
                Toggle("Creatine", isOn: bind(\.creatine, default: false))
                Toggle("Genoeg geslapen", isOn: bind(\.sleptEnough, default: false))
                ForEach(customHabits) { habit in
                    Toggle(habit.name, isOn: customBinding(habit.name))
                }
            }
            .listRowBackground(Color.cleanCard)

            Section("Slaap (optioneel)") {
                DatePicker("Naar bed", selection: sleepTime(\.bedTime, defaultHour: 23), displayedComponents: .hourAndMinute)
                DatePicker("Wakker", selection: sleepTime(\.wakeTime, defaultHour: 7), displayedComponents: .hourAndMinute)
                if let h = habitsRecord?.sleepHours {
                    LabeledContent("Geslapen", value: "\(h.kgText) uur")
                }
                Picker("Kwaliteit", selection: bind(\.sleepQuality, default: 0)) {
                    Text("—").tag(0)
                    Text("😴").tag(1)
                    Text("🙂").tag(2)
                    Text("😃").tag(3)
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.cleanCard)

            Section("Notitie") {
                TextField("Hoe ging deze dag?", text: bind(\.note, default: ""), axis: .vertical)
                    .lineLimit(3...8)
            }
            .listRowBackground(Color.cleanCard)

            Section("Eiwit — \(proteins.map(\.grams).reduce(0, +)) / \(profile.proteinTarget) g") {
                ForEach(proteins) { e in
                    LabeledContent {
                        Text("\(e.grams) g\(e.kcal > 0 ? " · \(e.kcal) kcal" : "")")
                    } label: {
                        Text(e.label)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(proteins[i]) }
                }
                Button { showProteinAlert = true } label: {
                    Label("Toevoegen", systemImage: "plus")
                }
            }
            .listRowBackground(Color.cleanCard)

            if !setsByExercise.isEmpty {
                Section("Training") {
                    ForEach(setsByExercise, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.headline)
                            Text(group.sets.map { "\($0.weightKg.kgText)×\($0.reps)" }.joined(separator: "  "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            for s in setsByExercise[i].sets { context.delete(s) }
                        }
                    }
                }
                .listRowBackground(Color.cleanCard)
            }

            Section("Gewicht") {
                ForEach(weights) { w in
                    LabeledContent {
                        Text("\(w.kg.kgText) kg")
                    } label: {
                        Text(w.date.formatted(date: .omitted, time: .shortened))
                        if !w.scale.isEmpty {
                            Text(w.scale).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(weights[i]) }
                }
                Button { showWeightAlert = true } label: {
                    Label("Toevoegen", systemImage: "plus")
                }
            }
            .listRowBackground(Color.cleanCard)
        }
        .cleanScreen()
        .tabBarClearance()
        .navigationTitle(cal.isDateInToday(day) ? "Vandaag" : day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Eiwit toevoegen", isPresented: $showProteinAlert) {
            TextField("Wat (bijv. Kwark)", text: $labelInput)
            TextField("Eiwit (g)", text: $gramsInput).keyboardType(.numberPad)
            TextField("Kcal (optioneel)", text: $kcalInput).keyboardType(.numberPad)
            Button("Toevoegen") {
                if let g = Int(gramsInput), g > 0 {
                    let label = labelInput.trimmingCharacters(in: .whitespaces)
                    context.insert(ProteinEntry(date: noon, grams: g,
                                                label: label.isEmpty ? "Eigen maaltijd" : label,
                                                kcal: Int(kcalInput) ?? 0))
                }
                labelInput = ""; gramsInput = ""; kcalInput = ""
            }
            Button("Annuleer", role: .cancel) { labelInput = ""; gramsInput = ""; kcalInput = "" }
        }
        .alert("Gewicht toevoegen", isPresented: $showWeightAlert) {
            TextField("bijv. 70,4", text: $weightInput).keyboardType(.decimalPad)
            Button("Opslaan") {
                if let kg = Double(weightInput.replacingOccurrences(of: ",", with: ".")), kg > 20 {
                    context.insert(WeightEntry(date: noon, kg: kg))
                }
                weightInput = ""
            }
            Button("Annuleer", role: .cancel) { weightInput = "" }
        }
    }
}
