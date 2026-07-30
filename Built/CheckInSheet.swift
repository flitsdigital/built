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

    private struct Question {
        let title: String
        let subtitle: String
        let icons: [String]
        let low: String
        let high: String
        let key: ReferenceWritableKeyPath<DayHabits, Int>
    }

    // Vijf vragen. Slaapkwaliteit bestond al (1–3) en hoort hier thuis i.p.v. weggestopt
    // in een aparte sheet — vandaar drie opties op die stap.
    private let questions: [Question] = [
        .init(title: "Hoeveel energie had je?", subtitle: "Over de hele dag genomen.",
              icons: ["😵", "🥱", "🙂", "💪", "⚡️"], low: "Leeg", high: "Vol gas", key: \.energy),
        .init(title: "Hoe voelde je je?", subtitle: "Je stemming, niet je prestatie.",
              icons: ["😞", "😕", "😐", "🙂", "😄"], low: "Slecht", high: "Top", key: \.mood),
        .init(title: "Hoeveel spierpijn?", subtitle: "Van je vorige trainingen.",
              icons: ["✅", "🙂", "😬", "😖", "🥵"], low: "Geen", high: "Veel", key: \.soreness),
        .init(title: "Hoe druk was je hoofd?", subtitle: "Stress van werk, school of privé.",
              icons: ["😌", "🙂", "😐", "😰", "🤯"], low: "Rustig", high: "Vol", key: \.stress),
        .init(title: "Hoe heb je geslapen?", subtitle: "De nacht hiervoor.",
              icons: ["😴", "🙂", "😃"], low: "Slecht", high: "Goed", key: \.sleepQuality),
    ]

    private var cal: Calendar { .current }
    private var record: DayHabits? { allHabits.first { cal.isDate($0.date, inSameDayAs: day) } }
    private var onSummary: Bool { step >= questions.count }

    private func recordOrCreate() -> DayHabits {
        if let record { return record }
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let h = DayHabits(date: cal.isDateInToday(day) ? .now : noon)
        context.insert(h)
        return h
    }

    private func value(_ q: Question) -> Int { record?[keyPath: q.key] ?? 0 }

    private var streak: Int {
        habitStreak { d in allHabits.first { cal.isDate($0.date, inSameDayAs: d) }?.checkedIn == true }
    }

    private func select(_ q: Question, _ level: Int) {
        let r = recordOrCreate()
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
                if onSummary { summary } else { questionStep(questions[step]) }
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
                Text(onSummary ? "KLAAR" : "STAP \(step + 1) VAN \(questions.count)")
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
                ForEach(questions.indices, id: \.self) { i in
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

    private func questionStep(_ q: Question) -> some View {
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

            HStack(spacing: q.icons.count > 3 ? 6 : 16) {
                ForEach(Array(q.icons.enumerated()), id: \.offset) { i, icon in
                    let level = i + 1
                    let selected = value(q) == level
                    Button {
                        select(q, level)
                    } label: {
                        Text(icon)
                            .font(.system(size: q.icons.count > 3 ? 32 : 40))
                            .frame(width: q.icons.count > 3 ? 58 : 76,
                                   height: q.icons.count > 3 ? 58 : 76)
                            .background(selected ? Color.green.opacity(0.16) : Color(.secondarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.green, lineWidth: selected ? 2 : 0)
                            }
                            .grayscale(selected ? 0 : 0.7)
                            .scaleEffect(selected ? 1.06 : 1)
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .accessibilityLabel("\(q.title) — \(level) van \(q.icons.count)")
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
                    .background(.orange.opacity(0.15), in: Capsule())
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
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .sensoryFeedback(.success, trigger: onSummary)
    }
}
