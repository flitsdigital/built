import SwiftUI
import SwiftData

/// Dag-check-in als drawer: één vraag per stap, grote knoppen, tikken schuift door.
/// Patroon uit stoic./WHOOP/Fable — stapindicator boven, ankerlabels onder de uitersten,
/// en een afsluiter met wat je invulde. Antwoorden worden direct bewaard, dus vroegtijdig
/// sluiten bewaart wat je al hebt beantwoord.
struct CheckInSheet: View {
    var day: Date = .now
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allHabits: [DayHabits]
    @State private var step = 0
    @State private var goingBack = false
    /// Los van de store: per toetsaanslag schrijven maakt van elke letter een
    /// sync-wijziging. Landt bij het doorschuiven en bij het sluiten.
    @State private var note = ""
    @FocusState private var noteFocused: Bool
    // Emoji schalen niet mee met Dynamic Type; @ScaledMetric doet dat alsnog, anders
    // krijgt wie grote letters nodig heeft juist hier de kleinste doelen.
    @ScaledMetric(relativeTo: .largeTitle) private var tileWide: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var tileNarrow: CGFloat = 58
    @ScaledMetric(relativeTo: .largeTitle) private var glyphWide: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var glyphNarrow: CGFloat = 32

    /// De vragen staan bij `DayHabits`: het dashboard, het logboek en de dagdetails tonen
    /// dezelfde schalen, en die hoorden niet vijf keer los te bestaan. Slaapkwaliteit
    /// bestond al (1–3) en hoort hier thuis i.p.v. weggestopt in een aparte sheet —
    /// vandaar drie opties op die stap.
    private var questions: [CheckIn] { DayHabits.checkIns }

    private var record: DayHabits? { allHabits.first { dayKey($0.date) == dayKey(day) } }
    private var onSummary: Bool { step > noteStep }

    private func value(_ q: CheckIn) -> Int { record?[keyPath: q.key] ?? 0 }

    /// De vrije tekst is de laatste stap; daarna pas de afsluiter.
    private var noteStep: Int { questions.count }
    private var stepCount: Int { questions.count + 1 }

    /// Alleen schrijven als er iets veranderd is: anders maakt het openen van de check-in
    /// al een `DayHabits`-rij aan voor een dag waar je verder niets invulde.
    private func saveNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (record?.checkInNote ?? "") else { return }
        context.habits(on: day).checkInNote = text
    }

    private var streak: Int {
        // Eén keer indexeren: habitStreak liep hier per dag opnieuw door alle dagen.
        let checkedIn = Set(allHabits.filter(\.checkedIn).map { dayKey($0.date) })
        return habitStreak { checkedIn.contains(dayKey($0)) }
    }

    private func select(_ q: CheckIn, _ level: Int) {
        let r = context.habits(on: day)
        r[keyPath: q.key] = r[keyPath: q.key] == level ? 0 : level
        guard r[keyPath: q.key] != 0 else { return } // wissen schuift niet door
        Task { // even laten landen zodat je je keuze ziet registreren
            try? await Task.sleep(for: .milliseconds(240))
            goingBack = false
            withAnimation(.snappy(duration: 0.3)) { step += 1 }
        }
    }

    private func back() {
        guard step > 0 else { return }
        goingBack = true
        withAnimation(.snappy(duration: 0.3)) { step -= 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Group {
                if onSummary { summary } else if step == noteStep { noteStepView }
                else { questionStep(questions[step]) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: goingBack ? .leading : .trailing).combined(with: .opacity),
                removal: .move(edge: goingBack ? .trailing : .leading).combined(with: .opacity)))
            .id(step)
        }
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.hidden)
        .sensoryFeedback(.selection, trigger: step)
        .interactiveDismissDisabled(false)
        .onAppear { note = record?.checkInNote ?? "" }
        // Wegvegen is hier een geldige manier om te stoppen, dus mag het niet wissen wat
        // je net typte.
        .onDisappear(perform: saveNote)
    }

    // MARK: - Kop: voortgang + terug/sluiten

    private var headerBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(step > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(step == 0)
                .accessibilityLabel("Vorige vraag")
                Spacer()
                Text(onSummary ? "KLAAR" : "STAP \(step + 1) VAN \(stepCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Sluiten")
            }
            HStack(spacing: 4) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.green : Color(.quaternarySystemFill))
                        .frame(height: 4)
                }
            }
            .animation(.snappy(duration: 0.3), value: step)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Eén vraag

    private func questionStep(_ q: CheckIn) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Text(q.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(q.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            let dense = q.icons.count > 3
            HStack(spacing: dense ? 6 : 16) {
                ForEach(Array(q.icons.enumerated()), id: \.offset) { i, icon in
                    let level = i + 1
                    let selected = value(q) == level
                    Button {
                        select(q, level)
                    } label: {
                        Text(icon)
                            .font(.system(size: dense ? glyphNarrow : glyphWide))
                            .frame(width: dense ? tileNarrow : tileWide,
                                   height: dense ? tileNarrow : tileWide)
                            .background(selected ? .builtTint(.green) : Color(.secondarySystemFill),
                                        in: RoundedRectangle(cornerRadius: BuiltRadius.medium + 4, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: BuiltRadius.medium + 4, style: .continuous)
                                    .strokeBorder(.green, lineWidth: selected ? 2 : 0)
                            }
                            .grayscale(selected ? 0 : 0.7)
                            .scaleEffect(selected ? 1.06 : 1)
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .accessibilityLabel("\(q.title) — \(level) van \(q.icons.count)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .animation(.snappy(duration: 0.2), value: value(q))

            HStack {
                Text(q.low)
                Spacer()
                Text(q.high)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 26)
            .padding(.top, 10)

            Spacer(minLength: 12)

            Button("Overslaan") {
                goingBack = false
                withAnimation(.snappy(duration: 0.3)) { step += 1 }
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Vrije tekst

    /// Vijf emoji-schalen vangen hoe een dag voelde, niet wat er gebeurde. Eén veld waarin
    /// je dat kwijt kunt, en dat je mag overslaan.
    private var noteStepView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Text("Wil je nog wat kwijt?")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Wat je hierboven niet in een emoji kwijt kon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            TextField("Vandaag was…", text: $note, axis: .vertical)
                .lineLimit(3...6)
                .focused($noteFocused)
                .font(.subheadline)
                .padding(12)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous))
                .padding(.horizontal, 20)

            Spacer(minLength: 12)

            // Leeg veld = overslaan, en dat is dezelfde tertiaire knop als op elke andere
            // stap. Een groene primaire knop die "Overslaan" zegt bijt met wat groen in
            // deze app betekent: gedaan, goed, actief.
            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Overslaan") { advance() }
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
            } else {
                Button {
                    advance()
                } label: {
                    Text("Bewaren")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .builtBottomAction()
            }
        }
        .animation(.snappy(duration: 0.2), value: note.isEmpty)
    }

    private func advance() {
        noteFocused = false
        saveNote()
        goingBack = false
        withAnimation(.snappy(duration: 0.3)) { step += 1 }
    }

    // MARK: - Afsluiter

    private var summary: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            Text("🎉").font(.system(size: 46))
            Text("Check-in compleet")
                .font(.title3.bold())
                .padding(.top, 8)
            if streak >= 2 {
                Text("🔥 \(streak) dagen op rij")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.builtTint(.orange), in: Capsule())
                    .padding(.top, 6)
            } else {
                Text("Morgen weer — dan begint je reeks te tellen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                ForEach(questions.indices, id: \.self) { i in
                    let q = questions[i]
                    let v = value(q)
                    Text(v > 0 ? q.icons[v - 1] : "–")
                        .font(.system(size: 24))
                        .frame(width: 48, height: 48)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: BuiltRadius.medium, style: .continuous))
                        .grayscale(v > 0 ? 0 : 1)
                        .opacity(v > 0 ? 1 : 0.4)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Text("Klaar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .builtBottomAction()
        }
        .sensoryFeedback(.success, trigger: onSummary)
    }
}
