import SwiftUI
import SwiftData

// Onboarding in Tonal-stijl: terug-pijl + voortgangsbalk, één gerichte vraag per
// stap, en een plan-reveal als finale. Geen swipe-pages → geen indicator-puntjes,
// en de knop bepaalt de flow (validatie kan niet omzeild worden).
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @State private var step = 0
    @State private var forward = true

    @State private var name = ""
    @State private var age = 22
    @State private var height = 176
    @State private var weight = 70.0
    @State private var goalWeight = 78.0
    @State private var goalDate = Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now
    @State private var trainings = 3
    @State private var trainingDays: [Int] = []
    @State private var started = false
    @State private var showLogin = false
    @State private var planRevealed = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let totalSteps = 4
    private var weeks: Double { max(goalDate.timeIntervalSinceNow / 604_800, 1) }
    private var rate: Double { (goalWeight - weight) / weeks }
    private var proteinTarget: Int { Int((goalWeight * 1.6).rounded()) }

    // Buiten deze grenzen levert het rekenwerk (Mifflin-St Jeor, eiwitdoel,
    // weektempo) stilletjes onzin op die overal doorwerkt. Ruim genomen.
    private let ageRange = 14...100
    private let heightRange = 120...230
    private let weightRange = 30.0...300.0

    private var weightValid: Bool { weightRange.contains(weight) }
    private var goalWeightValid: Bool { weightRange.contains(goalWeight) }

    /// Meer dan 30% verschil met je startgewicht is zelden haalbaar — wel melden,
    /// niet blokkeren: het is je eigen lichaam.
    private var goalWeightExtreme: Bool {
        weightValid && goalWeightValid && abs(goalWeight - weight) / weight > 0.3
    }

    private var weightRangeText: String {
        "\(Int(weightRange.lowerBound)) en \(Int(weightRange.upperBound)) kg"
    }

    private let weekdayOptions: [(day: Int, label: String)] = [
        (2, "Ma"), (3, "Di"), (4, "Wo"), (5, "Do"), (6, "Vr"), (7, "Za"), (1, "Zo"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch step {
                case 0: stepName
                case 1: stepBody
                case 2: stepGoal
                default: stepPlan
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showLogin) { AccountLoginSheet() }
    }

    private func go(_ to: Int) {
        forward = to > step
        nameFocused = false
        withAnimation(.snappy(duration: 0.35)) { step = to }
    }

    // MARK: - Bouwstenen

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                go(max(step - 1, 0))
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.bold())
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(step > 0 ? 1 : 0)
            .disabled(step == 0)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill))
                    Capsule()
                        .fill(.green)
                        .frame(width: geo.size.width * Double(step + 1) / Double(totalSteps))
                }
            }
            .frame(height: 4)
            .animation(.snappy(duration: 0.35), value: step)

            Text("\(step + 1)/\(totalSteps)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func title(_ big: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(big)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(sub)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func inputCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
            .padding(.horizontal, 20)
    }

    private func hint(_ text: String, warning: Bool = false) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.footnote)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private func primaryButton(_ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Stap 1: naam

    private var stepName: some View {
        VStack(spacing: 24) {
            title("Hoe mogen we je noemen?", "Je coach spreekt je graag aan.")
            inputCard {
                TextField("Je naam", text: $name)
                    .font(.title3)
                    .padding(16)
                    .focused($nameFocused)
                    .submitLabel(.next)
                    .onSubmit { if !trimmedName.isEmpty { go(1) } }
            }
            Spacer()
            primaryButton("Volgende", disabled: trimmedName.isEmpty) { go(1) }
            if Sync.isConfigured {
                Button("Al een account? Log in") { showLogin = true }
                    .font(.footnote)
                    .padding(.bottom, 12)
            }
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    // MARK: - Stap 2: over jou

    private var stepBody: some View {
        VStack(spacing: 24) {
            title("Over jou", "Hiermee rekenen we je plan uit.")
            inputCard {
                Stepper("Leeftijd: \(age)", value: $age, in: ageRange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider().padding(.leading, 16)
                Stepper("Lengte: \(height) cm", value: $height, in: heightRange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider().padding(.leading, 16)
                HStack {
                    Text("Huidig gewicht")
                    Spacer()
                    TextField("kg", value: $weight, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("kg").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            if !weightValid {
                hint("Vul een gewicht tussen \(weightRangeText) in.")
            }
            Spacer()
            primaryButton("Volgende", disabled: !weightValid) { go(2) }
        }
    }

    // MARK: - Stap 3: doel

    private var stepGoal: some View {
        VStack(spacing: 24) {
            title("Jouw doel", "Waar werken we naartoe?")
            inputCard {
                HStack {
                    Text("Doelgewicht")
                    Spacer()
                    TextField("kg", value: $goalWeight, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("kg").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider().padding(.leading, 16)
                DatePicker("Deadline", selection: $goalDate, in: Date.now..., displayedComponents: .date)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider().padding(.leading, 16)
                Stepper("Training: \(trainings)×/week", value: $trainings, in: 1...7)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            if !goalWeightValid {
                hint("Vul een doelgewicht tussen \(weightRangeText) in.")
            } else if goalWeightExtreme {
                hint("Dat scheelt meer dan 30% met je huidige gewicht. Mag, maar reken op een lange adem.", warning: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Vaste trainingsdagen (optioneel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(weekdayOptions, id: \.day) { option in
                        let on = trainingDays.contains(option.day)
                        Button {
                            if on {
                                trainingDays.removeAll { $0 == option.day }
                            } else {
                                trainingDays.append(option.day)
                            }
                        } label: {
                            Text(option.label)
                                .font(.caption.bold())
                                .frame(width: 38, height: 38)
                                .background(on ? Color.green : Color(.secondarySystemGroupedBackground), in: Circle())
                                .foregroundStyle(on ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            Spacer()
            primaryButton("Maak mijn plan", disabled: !goalWeightValid) {
                planRevealed = false
                go(3)
            }
        }
    }

    // MARK: - Stap 4: plan-reveal (Tonal: "Your goals are set!")

    private var stepPlan: some View {
        VStack(spacing: 24) {
            title("Je plan staat klaar, \(trimmedName)! 💪", "Dit is wat er elke dag nodig is — alles later aanpasbaar via je profiel.")
            VStack(spacing: 10) {
                planRow(0, label: "GEWICHT", value: "\(rate >= 0 ? "+" : "")\(rate.formatted(.number.precision(.fractionLength(2)))) kg per week")
                planRow(1, label: "EIWIT", value: "\(proteinTarget) g per dag")
                planRow(2, label: "TRAINING", value: trainingDays.isEmpty
                    ? "\(trainings)× per week"
                    : "\(trainings)× per week · \(trainingDayLabels)")
                planRow(3, label: "DOEL", value: "\(goalWeight.kgText) kg op \(goalDate.formatted(date: .long, time: .omitted))")
            }
            .padding(.horizontal, 20)
            Spacer()
            primaryButton("Start") {
                guard !started else { return }
                started = true
                let profile = Profile(name: trimmedName, age: age, heightCm: height,
                                      startWeight: weight, goalWeight: goalWeight, goalDate: goalDate,
                                      trainingsPerWeek: trainings)
                profile.trainingDays = trainingDays
                context.insert(profile)
                context.insert(WeightEntry(kg: weight))
            }
            if Sync.isConfigured {
                Text("Je gegevens staan op dit toestel. Koppel later een account via Profiel om ze veilig te stellen en tussen toestellen te synchroniseren.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.4).delay(0.15)) { planRevealed = true }
        }
    }

    private var trainingDayLabels: String {
        weekdayOptions.filter { trainingDays.contains($0.day) }.map(\.label).joined(separator: " · ")
    }

    private func planRow(_ index: Int, label: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                Text(value)
                    .font(.headline)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
        .opacity(planRevealed ? 1 : 0)
        .offset(y: planRevealed || reduceMotion ? 0 : 14)
        .animation(.snappy(duration: 0.4).delay(0.15 + Double(index) * 0.08), value: planRevealed)
    }
}
