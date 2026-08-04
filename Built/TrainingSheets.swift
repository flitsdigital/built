import SwiftUI
import SwiftData

// Alles wat vanuit het trainingsscherm wordt gepresenteerd: stopwatch, samenvatting,
// sessiedetail en de routine-editor. Losgetrokken uit TrainingView.swift — dat bestand
// was 2144 regels en niemand overzag het nog.

/// Stopwatch die optelt, naast de rusttimer die aftelt. Voor holds, intervallen en
/// cardio waar je zelf de tijd bepaalt.
///
/// Geen `Timer`: `Text(timerInterval:)` telt zelf door zolang het scherm leeft, ook als
/// de app tussendoor naar de achtergrond gaat. Pauzeren is daarom een som op `startedAt`
/// in plaats van een tikker die je stopt.
struct StopwatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0

    private var running: Bool { startedAt != nil }

    var body: some View {
        VStack(spacing: 20) {
            // Zonder deze twee regels is het een kaal getal met twee knoppen: niet duidelijk
            // waarvoor het is, en niet duidelijk of de tijd ergens landt. Dat laatste is de
            // vraag die je je stelt vlak voordat je 'm durft te gebruiken.
            VStack(spacing: 6) {
                Text("Stopwatch")
                    .font(.headline)
                Text("Voor holds, planks en intervallen. De rusttimer telt af, deze telt op — losse tijd, hij wordt niet bij je training opgeslagen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Group {
                if let startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                } else {
                    Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                }
            }
            .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())

            HStack(spacing: 12) {
                Button(running ? "Pauze" : (elapsed > 0 ? "Verder" : "Start")) {
                    if let startedAt {
                        elapsed = Date.now.timeIntervalSince(startedAt)
                        self.startedAt = nil
                    } else {
                        // Terugdateren i.p.v. optellen: dan blijft Text(timerInterval:)
                        // de enige bron van waarheid voor wat er op het scherm staat.
                        startedAt = Date.now.addingTimeInterval(-elapsed)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Reset") {
                    startedAt = nil
                    elapsed = 0
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!running && elapsed == 0)
            }
            .font(.headline)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: running)
    }
}

// MARK: - Afrond-summary (zeldzaam moment → delight mag)

struct WorkoutSummarySheet: View {
    let summary: WorkoutSummary
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var bounced = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: bounced)
                    .accessibilityHidden(true)
                Text("Sterk werk, \(name)! 💪")
                    .font(.title2.bold())
                HStack {
                    StatTile(value: "\(summary.minutes)", label: "minuten")
                    StatTile(value: "\(summary.volume)", label: "kg volume")
                    StatTile(value: "\(summary.sets)", label: "sets")
                }
                if let prev = summary.previousVolume, prev > 0 {
                    let delta = summary.volume - prev
                    Text("\(delta >= 0 ? "+" : "")\(delta) kg volume t.o.v. je vorige training")
                        .font(.footnote)
                        .foregroundStyle(delta >= 0 ? .green : .secondary)
                }
                if !summary.prs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.prs, id: \.exercise) { pr in
                            Text("🏆 \(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                                .font(.subheadline.bold())
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.builtTint(.yellow), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
                }
                if !summary.muscles.isEmpty {
                    VStack(spacing: 6) {
                        Text("Vandaag geraakt").font(.caption).foregroundStyle(.secondary)
                        BodyMapView(values: summary.muscles, figureHeight: 180)
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                ShareLink(item: summary.shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(height: 22)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delen")
                Button {
                    dismiss()
                } label: {
                    Text("Klaar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .builtBottomAction()
            .background(.regularMaterial)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { bounced = true }
        .sensoryFeedback(.success, trigger: bounced)
    }

}

/// Overzicht van één gedane training: duur, volume, verbeteringen — en bewerkbaar
/// (kg/reps aanpassen, set of oefening verwijderen).
struct SessionDetailView: View {
    let day: Date
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allHabits: [DayHabits]
    @Query private var exercises: [Exercise]
    @Query(sort: \WeightEntry.date) private var allWeights: [WeightEntry]
    @FocusState private var focused: UUID?

    /// Lichaamsgewicht rond een dag, voor het meetellen van bodyweight-oefeningen.
    private func bodyWeight(on d: Date) -> Double {
        (allWeights.last { $0.date <= d } ?? allWeights.last)?.kg ?? 0
    }

    private var cal: Calendar { .current }
    private var daySets: [SetEntry] {
        allSets.filter { dayKey($0.date) == dayKey(day) }.sorted { $0.date < $1.date }
    }

    private var habitsRecord: DayHabits? { allHabits.first { dayKey($0.date) == dayKey(day) } }

    private func record() -> DayHabits {
        if let h = habitsRecord { return h }
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let h = DayHabits(date: noon)
        context.insert(h)
        return h
    }

    private var workoutNoteBinding: Binding<String> {
        Binding(get: { habitsRecord?.workoutNote ?? "" },
                set: { record().workoutNote = $0 })
    }

    private var byExercise: [(name: String, sets: [SetEntry])] {
        var names: [String] = []
        for s in daySets where !names.contains(s.exercise) { names.append(s.exercise) }
        return names.map { n in (n, daySets.filter { $0.exercise == n }) }
    }

    private var volume: Int {
        Int(daySets.map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: day), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
    }

    private var durationText: String {
        guard let first = daySets.first?.date, let last = daySets.last?.date, last > first else { return "—" }
        let m = max(Int(last.timeIntervalSince(first) / 60), 1)
        return m >= 60 ? "\(m / 60)u \(m % 60)m" : "\(m) min"
    }

    /// Vorige trainingsdag die minstens één oefening deelt — basis voor de vergelijking.
    private var previousDay: Date? {
        let names = Set(daySets.map(\.exercise))
        let start = cal.startOfDay(for: day)
        return allSets.filter { $0.date < start && names.contains($0.exercise) }
            .map { cal.startOfDay(for: $0.date) }.max()
    }

    private var volumeDelta: Int? {
        guard let prev = previousDay else { return nil }
        let pv = Int(allSets.filter { dayKey($0.date) == dayKey(prev) }
            .map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: prev), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
        return pv > 0 ? volume - pv : nil
    }

    /// Oefeningen met een nieuw e1RM-record deze dag t.o.v. alles ervoor.
    private var prs: [(exercise: String, new: Double, old: Double)] {
        let start = cal.startOfDay(for: day)
        return byExercise.compactMap { group in
            let best = group.sets.map { epley($0.weightKg, $0.reps) }.max() ?? 0
            let before = allSets.filter { $0.exercise == group.name && $0.date < start }
                .map { epley($0.weightKg, $0.reps) }.max() ?? 0
            return best > before + 0.1 && before > 0 ? (group.name, best, before) : nil
        }
    }

    private func kg(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { set.weightKg }, set: { set.weightKg = $0 })
    }
    private func reps(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { Double(set.reps) }, set: { set.reps = Int(min($0.rounded(), 9999)) })
    }
    private func minutes(_ set: SetEntry) -> Binding<Double> {
        Binding(get: { Double(set.seconds / 60) }, set: { set.seconds = Int(min($0.rounded(), 600)) * 60 })
    }

    private var shareText: String {
        workoutShareText(title: "Training van \(day.formatted(.dateTime.weekday(.wide).day().month()))",
                         duration: durationText, volume: volume, sets: daySets.count,
                         lines: byExercise.map { group in
                             let bw = exercises.isBodyweight(group.name)
                             return "\(group.name): " + group.sets.map { setNotation(kg: $0.weightKg, reps: $0.reps, bodyweight: bw, seconds: $0.seconds) }.joined(separator: "  ")
                         },
                         prs: prs)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    StatTile(value: durationText, label: "duur")
                    StatTile(value: "\(volume)", label: "kg volume")
                    StatTile(value: "\(daySets.count)", label: "sets")
                }
                if let d = volumeDelta {
                    Text("\(d >= 0 ? "+" : "")\(d) kg volume t.o.v. je vorige training")
                        .font(.footnote)
                        .foregroundStyle(d >= 0 ? .green : .secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section("Notitie") {
                TextField("Notitie over deze training", text: workoutNoteBinding, axis: .vertical)
                    .lineLimit(1...6)
            }

            if !prs.isEmpty {
                Section("Records") {
                    ForEach(prs, id: \.exercise) { pr in
                        Text("🏆 \(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                            .font(.subheadline.bold())
                    }
                }
            }

            ForEach(byExercise, id: \.name) { group in
                Section(group.name) {
                    ForEach(Array(group.sets.enumerated()), id: \.element.persistentModelID) { i, set in
                        HStack(spacing: 12) {
                            Text("\(i + 1)\(set.dropset ? " D" : "")\(set.failure ? " F" : "")")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(set.dropset || set.failure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .frame(width: 40, alignment: .leading)
                            if exercises.isCardio(group.name) {
                                NumericField(value: minutes(set), decimal: false, placeholder: "min",
                                             focus: $focused, id: nil, disabled: false)
                                    .frame(width: 64)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text("min").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                NumericField(value: kg(set), decimal: true, placeholder: exercises.isBodyweight(group.name) ? "±kg" : "kg",
                                             focus: $focused, id: nil, disabled: false,
                                             signed: exercises.isBodyweight(group.name))
                                    .frame(width: 64)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text(exercises.isBodyweight(group.name) ? "±kg" : "kg").font(.footnote).foregroundStyle(.secondary)
                                NumericField(value: reps(set), decimal: false, placeholder: "reps",
                                             focus: $focused, id: nil, disabled: false)
                                    .frame(width: 52)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
                                Text("reps").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.deleteSynced(group.sets[i]) }
                    }
                    Button {
                        if let last = group.sets.last {
                            context.insert(SetEntry(date: last.date.addingTimeInterval(1),
                                                    exercise: group.name, weightKg: last.weightKg, reps: last.reps,
                                                    seconds: last.seconds))
                        }
                    } label: {
                        Label("Set toevoegen", systemImage: "plus")
                    }
                }
            }
        }
        .tabBarClearance()
        .navigationTitle(cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: shareText)
            EditButton()
        }
    }

}

/// Preview van een routine: zie wat je gaat doen, pas het aan, of start hem meteen.
struct RoutineEditorView: View {
    @Bindable var routine: Routine
    /// nil = alleen bewerken (bijv. vanuit onboarding); anders verschijnt de startknop.
    var onStart: ((Routine) -> Void)?
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query private var exercises: [Exercise]
    @State private var showPicker = false

    private func subtitle(for name: String) -> String {
        var parts: [String] = []
        if let t = routine.targets[name], t.count > 1 {
            parts.append(exercises.isCardio(name) ? "\(t[1]) min" : "\(t[0]) × \(t[1])")
        }
        if let group = routine.supersets[name] { parts.append("Superset \(group)") }
        let alts = routine.alternatives[name] ?? []
        if !alts.isEmpty { parts.append("Alt: \(alts.joined(separator: ", "))") }
        return parts.joined(separator: "  ·  ")
    }

    /// Wat je in totaal gaat doen — de kern van de preview.
    private var totals: String {
        let count = routine.exercises.count
        let setCount = routine.exercises.reduce(0) { $0 + (routine.targets[$1]?.first ?? 3) }
        return "\(count) oefening\(count == 1 ? "" : "en") · \(setCount) sets"
    }

    var body: some View {
        List {
            Section {
                ForEach(routine.exercises, id: \.self) { name in
                    NavigationLink {
                        RoutineExerciseEditor(routine: routine, exercise: name)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).foregroundStyle(.primary)
                                let sub = subtitle(for: name)
                                if !sub.isEmpty {
                                    Text(sub)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .onMove { routine.exercises.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for i in offsets {
                        routine.alternatives[routine.exercises[i]] = nil
                        routine.targets[routine.exercises[i]] = nil
                    }
                    routine.exercises.remove(atOffsets: offsets)
                }
                Button {
                    showPicker = true
                } label: {
                    Label("Oefening toevoegen", systemImage: "plus")
                }
            } header: {
                Text(routine.exercises.isEmpty ? "Oefeningen" : "\(totals) — sleep om de volgorde te bepalen")
            } footer: {
                Text("Tik op een oefening voor sets × reps en alternatieven. Tijdens de training wissel je via het ⋯-menu als een toestel bezet is.")
            }
        }
        // Volgorde telt: de startknop eerst, dan de tab-bar-ruimte eronder.
        .safeAreaInset(edge: .bottom) {
            if let onStart, !routine.exercises.isEmpty {
                Button {
                    onStart(routine)
                } label: {
                    Label("Start deze training", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .builtBottomAction()
            }
        }
        .tabBarClearance()
        .navigationTitle($routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $showPicker) {
            ExercisePickerSheet(exclude: Set(routine.exercises)) { name in
                if !routine.exercises.contains(name) { routine.exercises.append(name) }
            }
        }
    }
}

/// Per oefening: doel (sets × reps) en alternatieven.
struct RoutineExerciseEditor: View {
    @Bindable var routine: Routine
    let exercise: String
    @Query(sort: \SetEntry.date, order: .reverse) private var sets: [SetEntry]
    @Query private var exercises: [Exercise]
    @State private var showAltPicker = false

    private var cardio: Bool { exercises.isCardio(exercise) }
    private var target: [Int] { routine.targets[exercise] ?? (cardio ? [1, 20] : [3, 8]) }
    private func setTarget(sets s: Int, reps r: Int) { routine.targets[exercise] = [s, r] }

    var body: some View {
        List {
            Section {
                if cardio {
                    Stepper("Minuten: \(target[1])", value: Binding(
                        get: { target[1] },
                        set: { setTarget(sets: 1, reps: $0) }
                    ), in: 1...180, step: 5)
                } else {
                    Stepper("Sets: \(target[0])", value: Binding(
                        get: { target[0] },
                        set: { setTarget(sets: $0, reps: target[1]) }
                    ), in: 1...10)
                    Stepper("Reps: \(target[1])", value: Binding(
                        get: { target[1] },
                        set: { setTarget(sets: target[0], reps: $0) }
                    ), in: 1...30)
                }
            } header: {
                Text("Doel")
            } footer: {
                Text(cardio ? "Bij het starten van de routine staat \(target[1]) minuten klaar."
                            : "Bij het starten van de routine krijg je \(target[0]) sets van \(target[1]) reps voorgezet.")
            }

            Section {
                Picker("Superset", selection: Binding(
                    get: { routine.supersets[exercise] ?? "" },
                    set: { routine.supersets[exercise] = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Geen").tag("")
                    ForEach(["A", "B", "C", "D"], id: \.self) { Text("Groep \($0)").tag($0) }
                }
            } footer: {
                Text("Oefeningen in dezelfde groep doe je achter elkaar met weinig rust ertussen; de rusttimer start pas na de laatste van de groep.")
            }

            Section {
                Picker("Rusttijd", selection: Binding(
                    get: { routine.restByExercise[exercise] ?? 0 },
                    set: { routine.restByExercise[exercise] = $0 == 0 ? nil : $0 }
                )) {
                    Text("Standaard").tag(0)
                    Text("1:00").tag(60)
                    Text("1:30").tag(90)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                }
            } footer: {
                Text("Rust ná een set van deze oefening. \u{201C}Standaard\u{201D} volgt de instelling in je profiel.")
            }

            Section {
                ForEach(routine.alternatives[exercise] ?? [], id: \.self) { alt in
                    Text(alt)
                }
                .onDelete { offsets in
                    var alts = routine.alternatives[exercise] ?? []
                    alts.remove(atOffsets: offsets)
                    routine.alternatives[exercise] = alts.isEmpty ? nil : alts
                }
                Button {
                    showAltPicker = true
                } label: {
                    Label("Alternatief toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Alternatieven")
            } footer: {
                Text("Vervangers als dit toestel bezet of stuk is — kies je tijdens de training via het ⋯-menu.")
            }
        }
        .navigationTitle(exercise)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAltPicker) {
            ExercisePickerSheet(exclude: Set([exercise] + (routine.alternatives[exercise] ?? []))) { name in
                routine.alternatives[exercise, default: []].append(name)
            }
        }
    }
}

// MARK: - Numeriek invoerveld met cursor altijd achteraan

/// UITextField-wrapper: reformat gebeurt niet tijdens het typen (geen cursor-sprong)
/// en bij focus staat de cursor achteraan. Ondersteunt de autofocus-op-volgende-set.
struct NumericField: UIViewRepresentable {
    @Binding var value: Double
    var decimal: Bool
    var placeholder: String
    var focus: FocusState<UUID?>.Binding
    var id: UUID?
    var disabled: Bool
    /// Toont een ±-knop boven het toetsenbord. De decimalPad heeft geen minteken, en
    /// zonder die knop kun je assisted dips (−40 kg van je lichaamsgewicht) niet invoeren.
    var signed: Bool = false

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        context.coordinator.field = tf
        tf.delegate = context.coordinator
        tf.keyboardType = decimal ? .decimalPad : .numberPad
        tf.textAlignment = .center
        tf.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        tf.adjustsFontSizeToFitWidth = true
        tf.minimumFontSize = 11
        tf.placeholder = placeholder
        tf.text = context.coordinator.string(from: value)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        // Numpad heeft geen return-toets, dus zonder deze balk kun je het toetsenbord
        // alleen wegkrijgen door de lijst weg te slepen.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        var items: [UIBarButtonItem] = []
        if signed {
            items.append(UIBarButtonItem(title: "±", style: .plain, target: context.coordinator,
                                         action: #selector(Coordinator.toggleSign)))
        }
        items += [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                  UIBarButtonItem(title: "Klaar", style: .done,
                                  target: context.coordinator,
                                  action: #selector(Coordinator.dismissKeyboard))]
        bar.items = items
        bar.sizeToFit()
        tf.inputAccessoryView = bar
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self
        tf.isEnabled = !disabled
        // Alleen overschrijven als de gebruiker hier niet typt → geen cursor-sprong
        if !tf.isFirstResponder {
            let formatted = context.coordinator.string(from: value)
            if tf.text != formatted { tf.text = formatted }
        }
        if let id, focus.wrappedValue == id, !tf.isFirstResponder, !disabled {
            DispatchQueue.main.async { tf.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumericField
        weak var field: UITextField?
        init(_ parent: NumericField) { self.parent = parent }

        func string(from value: Double) -> String {
            if parent.decimal {
                return value == value.rounded()
                    ? String(Int(value))
                    : String(value).replacingOccurrences(of: ".", with: ",")
            }
            return String(Int(value))
        }

        @objc func toggleSign() {
            parent.value = -parent.value
            field?.text = string(from: parent.value)
        }

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }

        @objc func editingChanged(_ tf: UITextField) {
            let raw = (tf.text ?? "").replacingOccurrences(of: ",", with: ".")
            if let v = Double(raw) { parent.value = v }
            else if raw.isEmpty { parent.value = 0 }
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            if let id = parent.id { parent.focus.wrappedValue = id }
            let end = tf.endOfDocument
            tf.selectedTextRange = tf.textRange(from: end, to: end) // cursor achteraan
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            if let id = parent.id, parent.focus.wrappedValue == id { parent.focus.wrappedValue = nil }
            tf.text = string(from: parent.value)
        }
    }
}
