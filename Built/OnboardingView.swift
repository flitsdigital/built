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
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var creating = false
    @State private var authError: String?
    @State private var awaitingConfirmation = false
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

    // Live-checklist onder het wachtwoordveld: het patroon dat lululemon, Gymshark,
    // Acorns en Upside allemaal draaien — je ziet vooraf waaróm de knop uit staat.
    private var passwordRules: [(text: String, met: Bool)] {
        [("Minstens 8 tekens", password.count >= 8),
         ("Een hoofdletter", password.contains { $0.isUppercase }),
         ("Een kleine letter", password.contains { $0.isLowercase }),
         ("Een cijfer", password.contains { $0.isNumber })]
    }

    private var passwordValid: Bool { passwordRules.allSatisfy(\.met) }
    /// Bewust ruim: e-mailvalidatie die slimmer wil zijn wijst echte adressen af.
    private var emailValid: Bool {
        let t = trimmedEmail
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var accountValid: Bool { !trimmedName.isEmpty && emailValid && passwordValid }
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
                case 0: stepAccount
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
        .sheet(isPresented: $awaitingConfirmation) { confirmMailSheet }
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
            .accessibilityLabel("Vorige stap")
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
                .fixedSize(horizontal: false, vertical: true) // anders knipt 'ie af op één regel
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

    // MARK: - Stap 1: account (naam + e-mail + wachtwoord in één scherm)

    private var stepAccount: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    title("Maak je account", "Zo staat je voortgang veilig en heb je 'm op elk toestel bij de hand.")
                    inputCard {
                        TextField("Je naam", text: $name)
                            .textContentType(.givenName)
                            .padding(16)
                            .focused($nameFocused)
                        Divider().padding(.leading, 16)
                        TextField("E-mailadres", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(16)
                        Divider().padding(.leading, 16)
                        HStack {
                            Group {
                                if showPassword {
                                    TextField("Wachtwoord", text: $password)
                                } else {
                                    SecureField("Wachtwoord", text: $password)
                                }
                            }
                            .textContentType(.newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showPassword ? "Wachtwoord verbergen" : "Wachtwoord tonen")
                        }
                        .padding(16)
                    }
                    passwordChecklist
                    if let authError {
                        hint(authError, warning: true)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            primaryButton(creating ? "Bezig…" : "Volgende", disabled: !accountValid || creating) {
                createAccount()
            }
            Button("Al een account? Log in") { showLogin = true }
                .font(.footnote)
                .padding(.bottom, 12)
            Text("Door verder te gaan ga je akkoord met de voorwaarden en het privacybeleid.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
        }
        .onAppear { nameFocused = true }
    }

    private var passwordChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(passwordRules, id: \.text) { rule in
                Label {
                    Text(rule.text)
                } icon: {
                    Image(systemName: rule.met ? "checkmark.circle.fill" : "circle")
                }
                .font(.footnote)
                .foregroundStyle(rule.met ? Color.green : Color.secondary)
                .animation(.snappy(duration: 0.2), value: rule.met)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

    /// Account meteen aanmaken: pas als het echt gelukt is mag je door de rest van de
    /// onboarding. Zo loopt niemand vier stappen ver om alsnog op een bezet e-mailadres
    /// te stranden.
    private func createAccount() {
        guard Sync.isConfigured else { go(1); return } // zonder Supabase-config lokaal verder
        // Terug vanaf stap 2 en dan weer Volgende: het account bestaat al. Een tweede
        // signUp geeft bij een bestaand adres geen sessie terug (Supabase verklapt niet
        // dat het adres bezet is), en dat zou je in het bevestigingsscherm zetten terwijl
        // je gewoon ingelogd bent.
        guard !Sync.hasSession else { go(1); return }
        creating = true
        authError = nil
        Task {
            do {
                let signedIn = try await Sync.register(email: trimmedEmail, password: password, context: context)
                creating = false
                if signedIn {
                    go(1)
                } else {
                    awaitingConfirmation = true
                }
            } catch {
                creating = false
                authError = error.localizedDescription
            }
        }
    }

    /// Staat e-mailbevestiging aan in Supabase, dan geeft `signUp` geen sessie terug en
    /// kan de gebruiker niet verder. Deze sheet is de enige uitweg: bevestigen, dan hier
    /// inloggen met hetzelfde wachtwoord.
    private var confirmMailSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .padding(.top, 40)
            Text("Bevestig je e-mail")
                .font(.title2.bold())
            Text("We stuurden een link naar \(trimmedEmail). Tik 'm aan en kom hier terug.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let authError {
                hint(authError, warning: true)
            }
            Spacer()
            primaryButton(creating ? "Bezig…" : "Ik heb bevestigd", disabled: creating) {
                creating = true
                authError = nil
                Task {
                    do {
                        try await Sync.signIn(email: trimmedEmail, password: password, context: context)
                        creating = false
                        awaitingConfirmation = false
                        go(1)
                    } catch {
                        creating = false
                        authError = "Nog niet bevestigd — check je mail en probeer opnieuw."
                    }
                }
            }
            // Een typefout in je e-mailadres is de makkelijkste fout om te maken, en zonder
            // deze knop is de app afsluiten de enige uitweg.
            Button("Ander e-mailadres") {
                awaitingConfirmation = false
                authError = nil
            }
            .font(.footnote)
            .disabled(creating)
            .padding(.bottom, 20)
        }
        .interactiveDismissDisabled() // wel bewust: niet per ongeluk wegvegen
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
            if Sync.isConfigured, let email = Sync.currentEmail {
                Text("Opgeslagen op \(email) — je vindt je plan terug op elk toestel waar je inlogt.")
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
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
        .opacity(planRevealed ? 1 : 0)
        .offset(y: planRevealed || reduceMotion ? 0 : 14)
        .animation(.snappy(duration: 0.4).delay(0.15 + Double(index) * 0.08), value: planRevealed)
    }
}
