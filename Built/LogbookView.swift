import SwiftUI
import SwiftData

struct LogbookView: View {
    let profile: Profile
    /// Alleen de zichtbare tab rekent z'n body door. De view blijft in de
    /// hiërarchie staan, dus @State (zoals een lopende training) blijft leven.
    var isVisible = true
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]

    enum Filter: String, CaseIterable {
        case all = "Alles"
        case training = "Trainingsdagen"
        case notes = "Met check-in"
    }

    @State private var filter: Filter = .all

    private var cal: Calendar { .current }

    /// Eén keer per render bouwen en doorgeven — zie `DayIndex`.
    private func makeIndex() -> DayIndex {
        DayIndex(proteins: proteins, weights: weights, sets: sets, habits: habits)
    }

    private func days(_ idx: DayIndex) -> [Date] {
        var all = Set<Date>()
        for w in weights { all.insert(cal.startOfDay(for: w.date)) }
        for p in proteins { all.insert(cal.startOfDay(for: p.date)) }
        for s in sets { all.insert(cal.startOfDay(for: s.date)) }
        for h in habits { all.insert(cal.startOfDay(for: h.date)) }
        all.insert(cal.startOfDay(for: .now))
        return all.sorted(by: >).prefix(365).filter { matchesFilter($0, idx) }
    }

    private func matchesFilter(_ day: Date, _ idx: DayIndex) -> Bool {
        switch filter {
        case .all:
            return true
        case .training:
            return idx.trained(day)
        case .notes:
            return idx.habits(day)?.checkedIn == true
        }
    }

    /// Gegroepeerd per maand, nieuwste eerst.
    private func monthGroups(_ idx: DayIndex) -> [(month: Date, days: [Date])] {
        Dictionary(grouping: days(idx)) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0)) ?? $0
        }
        .map { (month: $0.key, days: $0.value.sorted(by: >)) }
        .sorted { $0.month > $1.month }
    }

    private func summary(_ day: Date, _ idx: DayIndex) -> String {
        var parts: [String] = []
        if idx.trained(day) { parts.append("Training") }
        let protein = idx.protein(day)
        if protein > 0 { parts.append("\(protein) g eiwit") }
        let kcal = idx.kcal(day)
        if kcal > 0 { parts.append("\(kcal) kcal") }
        if let kg = idx.weight(day) { parts.append("\(kg.kgText) kg") }
        if let hours = idx.habits(day)?.sleepHours { parts.append("\(hours.kgText) u slaap") }
        return parts.isEmpty ? "Niets gelogd" : parts.joined(separator: " · ")
    }

    /// De dag-check-in als emoji-regel. Dit ís het dagverhaal geworden: losse
    /// notities zijn eruit, de vijf vragen vertellen het beter en kosten minder.
    private func checkInIcons(_ day: Date, _ idx: DayIndex) -> String? {
        guard let h = idx.habits(day), h.checkedIn else { return nil }
        let scales = ["😵🥱🙂💪⚡️", "😞😕😐🙂😄", "✅🙂😬😖🥵", "😌🙂😐😰🤯", "😴🙂😃"]
        let values = [h.energy, h.mood, h.soreness, h.stress, h.sleepQuality]
        let icons = zip(scales, values).compactMap { scale, v -> String? in
            guard v > 0 else { return nil }
            let chars = Array(scale.map(String.init))
            return v <= chars.count ? chars[v - 1] : nil
        }
        return icons.isEmpty ? nil : icons.joined(separator: " ")
    }

    private func isPerfect(_ day: Date, _ idx: DayIndex) -> Bool {
        DayCheck.perfect(day, index: idx, profile: profile)
    }

    var body: some View {
        if isVisible { content } else { Color.clear }
    }

    @ViewBuilder private var content: some View {
        let idx = makeIndex()
        let groups = monthGroups(idx)
        // LazyVStack: alleen de maandkaarten in beeld worden gebouwd. Eerder stonden
        // hier tot 365 dagrijen tegelijk, elk met een volledige perfecte-dag-check.
        return ScrollView {
            LazyVStack(spacing: 14) {
                BuiltScreenTitle(eyebrow: "Logboek", title: "\(groups.reduce(0) { $0 + $1.days.count }) dagen") {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .background(.builtTint(.green), in: Circle())
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityValue(filter.rawValue) // actieve filter zit alleen in de icoonvariant
                }
                ForEach(groups, id: \.month) { group in
                    BuiltSectionHeader(group.month.formatted(.dateTime.month(.wide).year()))
                    // Eén kaart per maand, dagen als rijen erbinnen — dat leest als een
                    // logboek in plaats van als een instellingenlijst.
                    VStack(spacing: 0) {
                        ForEach(Array(group.days.enumerated()), id: \.element) { i, day in
                            if i > 0 { Divider().padding(.leading, 50) }
                            dayRow(day, idx)
                                .padding(.vertical, 10)
                                .background(cal.isDateInToday(day) ? Color.green.opacity(0.08) : .clear)
                        }
                    }
                    // clipShape omdat de "vandaag"-markering anders vierkante hoeken
                    // buiten de kaart steekt; .background(in:) klipt z'n inhoud niet.
                    .clipShape(RoundedRectangle(cornerRadius: BuiltRadius.card, style: .continuous))
                    .builtCard(padding: 0)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
    }

    private func dayRow(_ day: Date, _ idx: DayIndex) -> some View {
        let summary = summary(day, idx)
        let icons = checkInIcons(day, idx)
        // Een ingevulde check-in ís iets gelogd; anders stond er "Niets gelogd" met
        // de emoji's er pal onder.
        let empty = summary == "Niets gelogd" && icons == nil
        let isToday = cal.isDateInToday(day)
        return NavigationLink {
            DayDetailView(day: day, profile: profile)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.title3.bold().monospacedDigit())
                }
                .frame(width: 38)
                .overlay(alignment: .topTrailing) {
                    if isPerfect(day, idx) {
                        Circle().fill(.green).frame(width: 7, height: 7).offset(x: 4, y: -2)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if isToday || summary != "Niets gelogd" || icons == nil {
                        Text(isToday ? "Vandaag" : summary)
                            .font(.subheadline.weight(isToday ? .semibold : .regular))
                            .foregroundStyle(empty ? .secondary : .primary)
                    }
                    if isToday {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let icons {
                        Text(icons)
                            .font(.system(size: 15))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .opacity(empty && !isToday ? 0.55 : 1)
        }
        .buttonStyle(PressableStyle())
    }
}

struct DayDetailView: View {
    let profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var allWeights: [WeightEntry]
    @Query(sort: \ProteinEntry.date) private var allProteins: [ProteinEntry]
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allHabits: [DayHabits]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query private var habitLogs: [HabitLog]
    @Query private var exercises: [Exercise]

    @State private var day: Date
    @State private var showProteinSheet = false
    @State private var editingEntry: ProteinEntry?
    @State private var showWeightAlert = false
    @State private var weightInput = ""

    init(day: Date, profile: Profile) {
        self.profile = profile
        _day = State(initialValue: day)
    }

    private var cal: Calendar { .current }
    private var key: Int { dayKey(day) }
    private var weights: [WeightEntry] { allWeights.filter { dayKey($0.date) == key } }
    private var proteins: [ProteinEntry] { allProteins.filter { dayKey($0.date) == key } }
    private var daySets: [SetEntry] { allSets.filter { dayKey($0.date) == key } }
    private var habitsRecord: DayHabits? { allHabits.first { dayKey($0.date) == key } }

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
            get: { habitLogs.contains { $0.name == name && dayKey($0.date) == key } },
            set: { on in
                if on {
                    context.insert(HabitLog(name: name, date: noon))
                } else if let log = habitLogs.first(where: { $0.name == name && dayKey($0.date) == key }) {
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

    /// Vijf emoji als schaal; nogmaals tikken op dezelfde waarde wist 'm.
    private func checkInPicker(_ label: String, _ icons: [String],
                               _ keyPath: ReferenceWritableKeyPath<DayHabits, Int>) -> some View {
        let value = habitsRecord?[keyPath: keyPath] ?? 0
        return HStack {
            Text(label).frame(width: 76, alignment: .leading)
            Spacer()
            ForEach(1...5, id: \.self) { level in
                Button {
                    let r = record()
                    r[keyPath: keyPath] = r[keyPath: keyPath] == level ? 0 : level
                } label: {
                    Text(icons[level - 1])
                        .font(.system(size: 21))
                        .grayscale(value == level ? 0 : 1)
                        .opacity(value == level ? 1 : 0.35)
                        .frame(width: 36, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label) \(level) van 5")
            }
        }
        .animation(.snappy(duration: 0.2), value: value)
    }

    var body: some View {
        List {
            Section("Habits") {
                if profile.tracksCreatine {
                    Toggle("Creatine", isOn: bind(\.creatine, default: false))
                }
                if profile.tracksSleep {
                    Toggle("Genoeg geslapen", isOn: bind(\.sleptEnough, default: false))
                }
                if !profile.tracksCreatine && !profile.tracksSleep {
                    Text("Kern-habits staan uit — beheer ze via je profiel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !customHabits.isEmpty {
                Section("Eigen habits") {
                    ForEach(customHabits) { habit in
                        Toggle(habit.name, isOn: customBinding(habit.name))
                    }
                }
            }

            Section {
                checkInPicker("Energie", ["😵", "🥱", "🙂", "💪", "⚡️"], \.energy)
                checkInPicker("Stemming", ["😞", "😕", "😐", "🙂", "😄"], \.mood)
                checkInPicker("Spierpijn", ["✅", "🙂", "😬", "😖", "🥵"], \.soreness)
                checkInPicker("Stress", ["😌", "🙂", "😐", "😰", "🤯"], \.stress)
            } header: {
                Text("Check-in")
            } footer: {
                Text("Hoe die dag voelde. Nogmaals tikken op dezelfde waarde wist 'm. Dit voedt de correlaties in Inzicht.")
            }

            if let steps = HealthService.shared.steps(on: day) {
                Section("Health") {
                    LabeledContent("Stappen", value: steps.formatted())
                }
            }

            if profile.tracksSleep {
                Section("Slaap") {
                    if habitsRecord?.bedTime == nil && habitsRecord?.wakeTime == nil {
                        Button {
                            let r = record()
                            r.bedTime = cal.date(bySettingHour: 23, minute: 0, second: 0, of: day)
                            r.wakeTime = cal.date(bySettingHour: 7, minute: 0, second: 0, of: day)
                        } label: {
                            Label("Slaaptijden invullen", systemImage: "moon.zzz")
                        }
                    } else {
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
                }
            }

            Section("Eiwit — \(proteins.map(\.grams).reduce(0, +)) / \(profile.proteinTarget) g") {
                ForEach(mealSlots, id: \.self) { meal in
                    let list = proteins.filter { $0.mealKey == meal }
                    if !list.isEmpty {
                        Text(mealSlotNames[meal] ?? meal)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
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
                Button { showProteinSheet = true } label: {
                    Label("Toevoegen", systemImage: "plus")
                }
            }

            if !setsByExercise.isEmpty {
                Section("Training") {
                    if let wn = habitsRecord?.workoutNote, !wn.isEmpty {
                        Text(wn)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(setsByExercise, id: \.name) { group in
                        let bw = exercises.isBodyweight(group.name)
                        NavigationLink {
                            ExerciseDetailView(exercise: group.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.headline)
                                Text(group.sets.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            for s in setsByExercise[i].sets { context.delete(s) }
                        }
                    }
                }
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
        }
        .tabBarClearance()
        .navigationTitle(cal.isDateInToday(day) ? "Vandaag" : day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        day = cal.date(byAdding: .day, value: -1, to: day) ?? day
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel("Vorige dag")
                }
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        day = cal.date(byAdding: .day, value: 1, to: day) ?? day
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .accessibilityLabel("Volgende dag")
                }
                .disabled(cal.isDateInToday(day))
            }
        }
        .sheet(isPresented: $showProteinSheet) {
            ProteinEntrySheet(entryDate: noon)
        }
        .sheet(item: $editingEntry) { entry in
            ProteinEntrySheet(entry: entry)
        }
        .alert("Gewicht toevoegen", isPresented: $showWeightAlert) {
            TextField("bijv. 70,4", text: $weightInput).keyboardType(.decimalPad)
            Button("Opslaan") {
                if let kg = Double(weightInput.replacingOccurrences(of: ",", with: ".")), kg > 20 {
                    let date = cal.isDateInToday(day) ? Date.now : noon
                    context.insert(WeightEntry(date: date, kg: kg))
                }
                weightInput = ""
            }
            Button("Annuleer", role: .cancel) { weightInput = "" }
        }
    }
}
