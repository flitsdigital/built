import SwiftUI
import SwiftData

struct JournalView: View {
    let profile: Profile
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query private var proteins: [ProteinEntry]
    @Query private var sets: [SetEntry]
    @Query private var habits: [DayHabits]

    enum Filter: String, CaseIterable {
        case all = "Alles"
        case training = "Trainingsdagen"
        case notes = "Met notitie"
    }

    @State private var filter: Filter = .all

    private var cal: Calendar { .current }

    private var days: [Date] {
        var all = Set<Date>()
        for w in weights { all.insert(cal.startOfDay(for: w.date)) }
        for p in proteins { all.insert(cal.startOfDay(for: p.date)) }
        for s in sets { all.insert(cal.startOfDay(for: s.date)) }
        for h in habits { all.insert(cal.startOfDay(for: h.date)) }
        all.insert(cal.startOfDay(for: .now))
        return all.sorted(by: >).prefix(365).filter(matchesFilter)
    }

    private func matchesFilter(_ day: Date) -> Bool {
        switch filter {
        case .all:
            return true
        case .training:
            return sets.contains { cal.isDate($0.date, inSameDayAs: day) }
        case .notes:
            return note(day) != nil
        }
    }

    /// Gegroepeerd per maand, nieuwste eerst.
    private var monthGroups: [(month: Date, days: [Date])] {
        Dictionary(grouping: days) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0)) ?? $0
        }
        .map { (month: $0.key, days: $0.value.sorted(by: >)) }
        .sorted { $0.month > $1.month }
    }

    private func summary(_ day: Date) -> String {
        var parts: [String] = []
        if sets.contains(where: { cal.isDate($0.date, inSameDayAs: day) }) { parts.append("Training") }
        let dayProteins = proteins.filter { cal.isDate($0.date, inSameDayAs: day) }
        let protein = dayProteins.map(\.grams).reduce(0, +)
        if protein > 0 { parts.append("\(protein) g eiwit") }
        let kcal = dayProteins.map(\.kcal).reduce(0, +)
        if kcal > 0 { parts.append("\(kcal) kcal") }
        if let w = weights.last(where: { cal.isDate($0.date, inSameDayAs: day) }) { parts.append("\(w.kg.kgText) kg") }
        if let h = habits.first(where: { cal.isDate($0.date, inSameDayAs: day) }), let hours = h.sleepHours {
            parts.append("\(hours.kgText) u slaap")
        }
        return parts.isEmpty ? "Niets gelogd" : parts.joined(separator: " · ")
    }

    private func note(_ day: Date) -> String? {
        let texts = (habits.first { cal.isDate($0.date, inSameDayAs: day) }?.journal ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.text).filter { !$0.isEmpty }
        guard let latest = texts.first else { return nil }
        return texts.count > 1 ? "\(latest)  (+\(texts.count - 1))" : latest
    }

    private func isPerfect(_ day: Date) -> Bool {
        DayCheck.perfect(day, proteins: proteins, weights: weights, habits: habits,
                         target: profile.proteinTarget,
                         requireCreatine: profile.tracksCreatine, requireSleep: profile.tracksSleep,
                         sets: sets, trainingDays: profile.trainingDays)
    }

    var body: some View {
        List {
            ForEach(monthGroups, id: \.month) { group in
                Section(group.month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(group.days, id: \.self) { day in
                        dayRow(day)
                            .listRowBackground(cal.isDateInToday(day) ? Color.green.opacity(0.08) : nil)
                    }
                }
            }
        }
        .navigationTitle("Logboek")
        .toolbar {
            Menu {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    private func dayRow(_ day: Date) -> some View {
        NavigationLink {
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
                    if isPerfect(day) {
                        Circle().fill(.green).frame(width: 7, height: 7).offset(x: 4, y: -2)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cal.isDateInToday(day) ? "Vandaag" : summary(day))
                        .font(.subheadline.weight(cal.isDateInToday(day) ? .semibold : .regular))
                        .foregroundStyle(summary(day) == "Niets gelogd" ? .secondary : .primary)
                    if cal.isDateInToday(day) {
                        Text(summary(day))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let note = note(day) {
                        HStack(spacing: 6) {
                            Rectangle().fill(.green.opacity(0.5)).frame(width: 3)
                            Text(note)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .opacity(summary(day) == "Niets gelogd" && !cal.isDateInToday(day) ? 0.55 : 1)
        }
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

    // MARK: - Journal (meerdere notities per dag)

    private var journalEntries: [JournalNote] {
        (habitsRecord?.journal ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private func journalBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { habitsRecord?.journal.first { $0.id == id }?.text ?? "" },
            set: { newText in
                let r = record()
                if let i = r.journal.firstIndex(where: { $0.id == id }) { r.journal[i].text = newText }
            })
    }

    private func addJournalEntry() {
        let stamp = cal.isDateInToday(day) ? Date.now : noon
        withAnimation(.snappy(duration: 0.2)) { record().journal.append(JournalNote(text: "", createdAt: stamp)) }
    }

    private func deleteJournalEntries(_ offsets: IndexSet) {
        let ids = offsets.map { journalEntries[$0].id }
        record().journal.removeAll { ids.contains($0.id) }
    }

    /// Lege entries opruimen bij het verlaten, zodat een per ongeluk toegevoegde notitie niet blijft staan.
    private func pruneEmptyJournal() {
        habitsRecord?.journal.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

            Section {
                if journalEntries.isEmpty {
                    ContentUnavailableView("Nog geen notities", systemImage: "text.quote",
                                           description: Text("Schrijf hoe je dag ging — dat leest later terug als een logboek."))
                }
                ForEach(journalEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("Schrijf iets…", text: journalBinding(entry.id), axis: .vertical)
                            .lineLimit(1...12)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete(perform: deleteJournalEntries)
                Button { addJournalEntry() } label: {
                    Label("Notitie toevoegen", systemImage: "square.and.pencil")
                }
            } header: {
                Text("Journal")
            }

            Section("Eiwit — \(proteins.map(\.grams).reduce(0, +)) / \(profile.proteinTarget) g") {
                ForEach(mealOrder, id: \.self) { meal in
                    let list = proteins.filter { $0.mealKey == meal }
                    if !list.isEmpty {
                        Text(mealNames[meal] ?? meal)
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
        .onDisappear(perform: pruneEmptyJournal)
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
