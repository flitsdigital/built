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

/// Volgorde wisselen tijdens een lopende training: een toestel is bezet, of je besluit
/// halverwege eerst iets anders te doen.
///
/// Waarom een sheet en geen sleepgreep in het logscherm zelf: daar is elke oefening een
/// `Section` met z'n eigen sets, kolomkoppen en swipe-acties eronder, en secties laten
/// zich niet slepen. Dit is dezelfde greep als in de routine-editor, op een lijst die
/// verder niets doet — en tijdens het slepen zie je in één blik de hele training, wat in
/// het logscherm nooit lukt.
struct WorkoutOrderSheet: View {
    @Binding var workout: [DraftExercise]
    @Environment(\.dismiss) private var dismiss

    /// Zelfde opzet als de regel onder een oefening in de routine-editor: waar je staat,
    /// en of er een superset aan hangt.
    private func subtitle(_ ex: DraftExercise) -> String {
        let work = ex.sets.filter { !$0.warmup }
        var parts = ["\(work.filter(\.done).count)/\(work.count) sets"]
        if let group = ex.superset { parts.append("Superset \(group)") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(workout) { ex in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ex.name)
                            Text(subtitle(ex))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onMove { workout = workout.reordered(moving: $0, to: $1) }
                } footer: {
                    Text("Alleen de volgorde verandert — je afgevinkte sets houden hun eigen tijd. Sleep je een oefening uit een superset weg, dan valt hij eruit: de korte rust hoort bij oefeningen die naast elkaar staan.")
                }
            }
            // Altijd in edit-modus: slepen is het enige wat dit scherm doet, dus een
            // EditButton zou een knop zijn voor de enige stand die er is.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Volgorde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar") { dismiss() }.font(.body.bold())
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Overzicht van één gedane training: duur, volume, verbeteringen — en bewerkbaar
/// (kg/reps aanpassen, set of oefening verwijderen).
struct SessionDetailView: View {
    /// De training zoals de historie hem toonde. De sets komen hieronder vers uit de
    /// store — dit scherm is bewerkbaar, dus de momentopname zou meteen verlopen zijn.
    let session: WorkoutSession
    @Environment(\.modelContext) private var context
    @Query(sort: \SetEntry.date) private var allSets: [SetEntry]
    @Query private var allHabits: [DayHabits]
    @Query private var exercises: [Exercise]
    @Query(sort: \WeightEntry.date) private var allWeights: [WeightEntry]
    @FocusState private var focused: UUID?
    @State private var showPicker = false
    /// De zojuist gemaakte routine, om meteen naartoe te navigeren.
    @State private var newRoutine: Routine?
    /// De sessiesleutel leeft in state: verplaats je de training, dan verhuist z'n dag
    /// mee en klopt `session.id` niet meer.
    @State private var key: String

    init(session: WorkoutSession) {
        self.session = session
        _key = State(initialValue: session.id)
    }

    /// Lichaamsgewicht rond een dag, voor het meetellen van bodyweight-oefeningen.
    private func bodyWeight(on d: Date) -> Double {
        (allWeights.last { $0.date <= d } ?? allWeights.last)?.kg ?? 0
    }

    private var cal: Calendar { .current }
    /// Uit de sets zelf, niet uit `session`: die is een momentopname van vóór een verplaatsing.
    private var day: Date { cal.startOfDay(for: daySets.first?.date ?? session.date) }
    /// De sets van déze training, niet van de hele dag — er kunnen er twee zijn.
    private var daySets: [SetEntry] {
        allSets.filter { $0.sessionKey == key }.sorted { $0.date < $1.date }
    }

    private var habitsRecord: DayHabits? { allHabits.first { dayKey($0.date) == dayKey(day) } }
    private var workoutName: String { habitsRecord?.name(for: key) ?? "" }

    private var workoutNoteBinding: Binding<String> {
        Binding(get: { habitsRecord?.note(for: key) ?? "" },
                set: { context.habits(on: day).workoutNotes[key] = $0 })
    }

    private var workoutNameBinding: Binding<String> {
        Binding(get: { workoutName }, set: { context.habits(on: day).workoutNames[key] = $0 })
    }

    private var dayBinding: Binding<Date> {
        Binding(get: { day }, set: { move(to: $0) })
    }

    /// Verplaatst de hele training naar een andere dag: elke set schuift hetzelfde aantal
    /// dagen op (tijdstippen blijven, dus de duur klopt nog), en naam en notitie verhuizen
    /// naar de dagrecord van de nieuwe datum.
    private func move(to newDay: Date) {
        let rows = daySets
        guard let first = rows.first else { return }
        let delta = cal.startOfDay(for: newDay).timeIntervalSince(cal.startOfDay(for: first.date))
        guard delta != 0 else { return }
        let old = habitsRecord
        let name = old?.name(for: key) ?? ""
        let note = old?.note(for: key) ?? ""
        // Sets van vóór `workoutID` hangen aan hun dag, dus zou de sleutel meeverhuizen
        // en de training samenvallen met wat er op de nieuwe dag al stond.
        let id = first.workoutID == .zero ? UUID() : first.workoutID
        for s in rows {
            s.date = s.date.addingTimeInterval(delta)
            s.workoutID = id
        }
        old?.workoutNames[key] = nil
        old?.workoutNotes[key] = nil
        key = id.uuidString
        let target = context.habits(on: cal.startOfDay(for: newDay))
        if !name.isEmpty { target.workoutNames[key] = name }
        if !note.isEmpty { target.workoutNotes[key] = note }
    }

    private var byExercise: [(name: String, sets: [SetEntry])] { daySets.byExercise() }

    /// De training waar nieuwe sets aan hangen. Bij een lege training — je logt er een na
    /// die je niet live hebt bijgehouden — staat het id alleen nog in de sleutel.
    private var workoutID: UUID {
        daySets.first?.workoutID ?? UUID(uuidString: key) ?? .zero
    }

    private var volume: Int {
        Int(daySets.map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: day), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
    }

    private var durationText: String {
        guard let first = daySets.first?.date, let last = daySets.last?.date, last > first else { return "—" }
        let m = max(Int(last.timeIntervalSince(first) / 60), 1)
        return m >= 60 ? "\(m / 60)u \(m % 60)m" : "\(m) min"
    }

    /// Vorige training die minstens één oefening deelt — basis voor de vergelijking.
    /// Terugscannen vanaf de eerste set van nu; de hele historie in sessies hakken om er
    /// één uit te pakken was duur en zei niet meer.
    private var previousSession: (date: Date, sets: [SetEntry])? {
        let names = Set(daySets.map(\.exercise))
        guard let start = daySets.first?.date else { return nil }
        let earlier = allSets.filter { $0.date < start } // @Query levert oplopend op datum
        guard let match = earlier.last(where: { names.contains($0.exercise) }) else { return nil }
        let rows = earlier.filter { $0.sessionKey == match.sessionKey }
        return (rows.first?.date ?? match.date, rows)
    }

    private var volumeDelta: Int? {
        guard let prev = previousSession else { return nil }
        let pv = Int(prev.sets
            .map { liftLoad(kg: $0.weightKg, bodyweight: bodyWeight(on: prev.date), bodyweightExercise: exercises.isBodyweight($0.exercise)) * Double($0.reps) }.reduce(0, +))
        return pv > 0 ? volume - pv : nil
    }

    /// Oefeningen met een nieuw e1RM-record in deze training t.o.v. alles ervoor. Vanaf
    /// de eerste set, niet vanaf middernacht: anders telt een training van diezelfde
    /// ochtend niet mee als "ervoor".
    private var prs: [(exercise: String, new: Double, old: Double)] {
        let start = daySets.first?.date ?? cal.startOfDay(for: day)
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
        ScrollView {
            LazyVStack(spacing: 14) {
                headerCard
                if !prs.isEmpty { recordsCard }
                ForEach(byExercise, id: \.name) { group in
                    exerciseCard(group)
                }
                actionsCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .tabBarClearance()
        .navigationTitle(workoutName.isEmpty
                         ? (cal.isDateInToday(day) ? "Vandaag" : day.formatted(.dateTime.weekday(.wide).day().month()))
                         : workoutName)
        .navigationBarTitleDisplayMode(.inline)
        // Geen EditButton meer: die hoort bij een List, en verwijderen gebeurt nu via het
        // ⋯-menu van een oefening en het houd-ingedrukt-menu van een set.
        .toolbar { ShareLink(item: shareText) }
        .sheet(isPresented: $showPicker) {
            // Dezelfde oefening twee keer heeft hier geen zin: de sets zijn per naam
            // gegroepeerd, dus die zouden bij de bestaande rij landen.
            ExercisePickerSheet(exclude: Set(byExercise.map(\.name))) { name in
                // Een minuut na de vorige set, zodat de volgorde klopt; bij een lege
                // training is de dag zelf het startpunt.
                let start = daySets.last?.date ?? session.date
                context.insert(SetEntry(date: start.addingTimeInterval(60), exercise: name,
                                        weightKg: 0, reps: 0, workoutID: workoutID))
            }
        }
        .navigationDestination(item: $newRoutine) { RoutineEditorView(routine: $0) }
    }

    // MARK: - Kaarten

    private var headerCard: some View {
        VStack(spacing: 12) {
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
            Divider()
            field { TextField("Naam (bijv. Push A)", text: workoutNameBinding).font(.subheadline) }
            // Zonder sets valt er niets te verplaatsen: de training staat al op de dag
            // waar je 'm begon.
            if !daySets.isEmpty {
                DatePicker("Datum", selection: dayBinding, in: ...Date.now, displayedComponents: .date)
                    .font(.subheadline)
            }
            field {
                TextField("Notitie over deze training", text: workoutNoteBinding, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...6)
            }
        }
        .builtCard()
    }

    /// In een kaart heeft een tekstveld geen lijstrij om zich aan vast te houden, dus
    /// krijgt het zelf een vlak — anders leest het als gewone tekst.
    private func field<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous))
    }

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🏆 Nieuw record").font(.caption.bold()).foregroundStyle(.orange)
            ForEach(prs, id: \.exercise) { pr in
                Text("\(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                    .font(.subheadline)
            }
        }
        .builtCard()
    }

    private func exerciseCard(_ group: (name: String, sets: [SetEntry])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.name).font(.headline)
                Spacer()
                Menu {
                    Button("Verwijder oefening", systemImage: "trash", role: .destructive) {
                        for s in group.sets { context.deleteSynced(s) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Acties voor \(group.name)")
            }
            ForEach(Array(group.sets.enumerated()), id: \.element.persistentModelID) { i, set in
                setRow(i, set, group.name)
            }
            Button {
                if let last = group.sets.last {
                    // Zelfde sessie als de rij erboven, anders valt de nieuwe set buiten
                    // deze training.
                    context.insert(SetEntry(date: last.date.addingTimeInterval(1),
                                            exercise: group.name, weightKg: last.weightKg, reps: last.reps,
                                            seconds: last.seconds, workoutID: last.workoutID))
                }
            } label: {
                Label("Set toevoegen", systemImage: "plus").font(.subheadline)
            }
        }
        .builtCard()
    }

    private func setRow(_ i: Int, _ set: SetEntry, _ name: String) -> some View {
        HStack(spacing: 12) {
            Text("\(i + 1)\(set.dropset ? " D" : "")\(set.failure ? " F" : "")")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(set.dropset || set.failure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 40, alignment: .leading)
            if exercises.isCardio(name) {
                NumericField(value: minutes(set), decimal: false, placeholder: "min",
                             focus: $focused, id: nil, disabled: false)
                    .numericFieldChrome(width: 64)
                Text("min").font(.footnote).foregroundStyle(.secondary)
            } else {
                NumericField(value: kg(set), decimal: true, placeholder: exercises.isBodyweight(name) ? "±kg" : "kg",
                             focus: $focused, id: nil, disabled: false,
                             signed: exercises.isBodyweight(name))
                    .numericFieldChrome(width: 64)
                Text(exercises.isBodyweight(name) ? "±kg" : "kg").font(.footnote).foregroundStyle(.secondary)
                NumericField(value: reps(set), decimal: false, placeholder: "reps",
                             focus: $focused, id: nil, disabled: false)
                    .numericFieldChrome(width: 52)
                Text("reps").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        // Vegen bestaat niet buiten een List; ingedrukt houden is wat ervoor in de plaats komt.
        .contextMenu {
            Button("Verwijder set \(i + 1)", systemImage: "trash", role: .destructive) {
                context.deleteSynced(set)
            }
        }
        .accessibilityAction(named: "Verwijder set \(i + 1)") { context.deleteSynced(set) }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showPicker = true } label: {
                Label("Oefening toevoegen", systemImage: "plus")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if daySets.isEmpty {
                Text("Nog niets gelogd. Kies een oefening; kg en reps vul je hier in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Divider().padding(.vertical, 12)
                Button { makeRoutine() } label: {
                    Label("Maak routine van deze training", systemImage: "square.stack.3d.up")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .builtCard()
    }

    /// De routine krijgt bewust géén doelen mee: hij ís de volgorde van je oefeningen.
    /// Wat je vorige keer tilde staat tijdens de training toch al bij elke oefening, en
    /// een doel dat van één training is afgeleid is een gok die je daarna moet corrigeren.
    private func makeRoutine() {
        let routine = Routine(name: workoutName.isEmpty ? "Nieuwe routine" : workoutName,
                              exercises: byExercise.map(\.name))
        context.insert(routine)
        newRoutine = routine
    }
}

/// Preview van een routine: zie wat je gaat doen, pas het aan, of start hem meteen.
struct RoutineEditorView: View {
    @Bindable var routine: Routine
    /// nil = alleen bewerken (bijv. vanuit onboarding); anders verschijnt de startknop.
    var onStart: ((Routine) -> Void)?
    @Environment(\.modelContext) private var context
    @Query private var exercises: [Exercise]
    @State private var showPicker = false
    /// De zojuist gemaakte routine, om meteen naartoe te navigeren.
    @State private var newRoutine: Routine?

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

extension View {
    /// Het kader om een `NumericField`: overal dezelfde hoogte, hoek en vulling.
    /// `dimmed` voor een afgevinkte set, die naar de achtergrond mag.
    func numericFieldChrome(width: CGFloat, dimmed: Bool = false) -> some View {
        frame(width: width)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.small))
            .opacity(dimmed ? 0.55 : 1)
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
