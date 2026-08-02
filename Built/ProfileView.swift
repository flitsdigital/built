import SwiftUI
import SwiftData

struct ProfileView: View {
    @Bindable var profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \Scale.name) private var scales: [Scale]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]

    @AppStorage("restSeconds") private var restSeconds = 120
    // Zelfde keys als NotificationsSettingsView → status-badge blijft live kloppen
    @AppStorage("notifMorningOn") private var notifMorningOn = false
    @AppStorage("notifEveningOn") private var notifEveningOn = false
    @AppStorage("notifStreakOn") private var notifStreakOn = true
    @AppStorage("notifWeekOn") private var notifWeekOn = true
    @AppStorage("notifReviewOn") private var notifReviewOn = true
    @AppStorage("notifRestOn") private var notifRestOn = true
    @AppStorage("healthStepsOn") private var healthOn = false
    @AppStorage("notifCheckInOn") private var notifCheckInOn = true

    @State private var showAddScale = false
    @State private var scaleName = ""
    @State private var showAddHabit = false
    @State private var habitName = ""
    @State private var busy = false
    @State private var backupMessage: String?
    @State private var confirmRestore = false
    @State private var showLogin = false
    @State private var confirmLogout = false
    @State private var confirmDelete = false
    @State private var confirmNewPhase = false
    @State private var renameHabit: CustomHabit?
    @State private var renameText = ""
    @State private var habitToDelete: CustomHabit?
    @State private var scaleToDelete: Scale?
    @State private var calMessage: String?
    @State private var calBusy = false
    private let syncStatus = SyncStatus.shared

    private let weekdayOptions: [(day: Int, label: String)] = [
        (2, "Ma"), (3, "Di"), (4, "Wo"), (5, "Do"), (6, "Vr"), (7, "Za"), (1, "Zo"),
    ]

    private var activeNotifs: Int {
        [notifMorningOn, notifEveningOn, notifStreakOn, notifWeekOn, notifReviewOn, notifRestOn, notifCheckInOn]
            .filter { $0 }.count
    }

    private var trainingDaysSummary: String? {
        let picked = weekdayOptions.filter { profile.trainingDays.contains($0.day) }.map(\.label)
        guard !picked.isEmpty else { return nil }
        return "Gekozen: \(picked.joined(separator: ", "))"
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var autoKcal: Int {
        profile.autoKcalTarget(currentWeight: weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? profile.startWeight)
    }

    private var weightCSV: String {
        var lines = ["datum,kg,weegschaal"]
        let df = Date.FormatStyle(date: .numeric, time: .shortened)
        for w in weights {
            lines.append("\(w.date.formatted(df)),\(w.kg),\(w.scale)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Text(profile.name.isEmpty ? "💪" : String(profile.name.prefix(1)).uppercased())
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                        .frame(width: 52, height: 52)
                        .background(.builtTint(.green), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.isEmpty ? "Jij" : profile.name)
                            .font(.headline)
                        Text("\(profile.startWeight.kgText) → \(profile.goalWeight.kgText) kg · dag \(profile.daysIn)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Naam") {
                    TextField("Naam", text: $profile.name).multilineTextAlignment(.trailing)
                }
                LabeledContent("Doelgewicht") {
                    HStack(spacing: 4) {
                        TextField("75", value: $profile.goalWeight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("kg").foregroundStyle(.secondary)
                    }
                }
                DatePicker("Deadline", selection: $profile.goalDate, in: Date.now..., displayedComponents: .date)
                Stepper("Training: \(profile.trainingsPerWeek)×/week", value: $profile.trainingsPerWeek, in: 1...7)
                LabeledContent("Lengte") {
                    HStack(spacing: 4) {
                        TextField("180", value: $profile.heightCm, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("cm").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Leeftijd") {
                    TextField("25", value: $profile.age, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                Button("Nieuwe fase starten") { confirmNewPhase = true }
            } header: {
                Text("Jouw doel")
            } footer: {
                Text("\"Nieuwe fase starten\" herijkt je startpunt naar je huidige gewicht en vandaag — handig bij een nieuwe cut of bulk. Je historie blijft staan.")
            }

            Section {
                LabeledContent("Eiwitdoel", value: "\(profile.proteinTarget) g/dag")
                LabeledContent("Tempo", value: "\(profile.weeklyRate >= 0 ? "+" : "")\(profile.weeklyRate.formatted(.number.precision(.fractionLength(2)))) kg/week")
                LabeledContent("Calorie-doel") {
                    HStack(spacing: 4) {
                        TextField("\(autoKcal)", value: Binding(
                            get: { profile.kcalTarget == 0 ? nil : profile.kcalTarget },
                            set: { profile.kcalTarget = $0 ?? 0 }
                        ), format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("kcal").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Berekend uit je doel")
            } footer: {
                if profile.weeklyRate > 0.5 {
                    Label("Meer dan +0,5 kg/week wordt vooral vet. Overweeg een latere deadline.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Eiwitdoel = doelgewicht × 1,6. Calorie-doel leeg = automatisch (\(autoKcal) kcal): verbruik op basis van lengte, gewicht, leeftijd en trainingen, plus het overschot voor \(profile.weeklyRate >= 0 ? "+" : "")\(profile.weeklyRate.formatted(.number.precision(.fractionLength(1)))) kg/week.")
                }
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(weekdayOptions, id: \.day) { option in
                        let on = profile.trainingDays.contains(option.day)
                        Button {
                            if on {
                                profile.trainingDays.removeAll { $0 == option.day }
                            } else {
                                profile.trainingDays.append(option.day)
                            }
                        } label: {
                            Text(option.label)
                                .font(.caption.bold())
                                .frame(width: 38, height: 38)
                                .background(on ? Color.green : Color(.tertiarySystemFill), in: Circle())
                                .foregroundStyle(on ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            } header: {
                Text("Trainingsdagen")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let trainingDaysSummary {
                        Text(trainingDaysSummary)
                    }
                    Text("Optioneel. Met vaste dagen telt \"rustdag volgens plan\" mee als perfect, en herinneren meldingen je alleen op trainingsdagen.")
                }
            }

            Section {
                Toggle("Creatine bijhouden", isOn: $profile.tracksCreatine)
                Toggle("Slaap bijhouden", isOn: $profile.tracksSleep)
                Toggle("Eten bijhouden", isOn: $profile.tracksFood)
                if profile.tracksFood {
                    Toggle("Eten telt mee voor je Groei Score", isOn: $profile.foodCountsForScore)
                }
            } header: {
                Text("Kern-habits")
            } footer: {
                Text("Je Groei Score telt nu: wegen, training\(profile.scoresFood ? ", eiwit" : "")\(profile.tracksCreatine ? ", creatine" : "")\(profile.tracksSleep ? ", slaap" : ""). Uitgeschakelde habits verdwijnen uit je checklist en tellen niet mee voor streak en perfecte dagen.\n\nEten bijhouden uit? Dan blijft de Eten-tab werken, maar verdwijnt de eiwitkaart van je dashboard. Wil je wél blijven loggen maar niet afgerekend worden op de dagen dat je het overslaat, zet dan alleen \"telt mee voor je Groei Score\" uit — de kaart blijft dan gewoon staan.")
            }

            Section {
                Toggle("Stappen uit Health", isOn: Binding(
                    get: { healthOn },
                    set: { on in
                        healthOn = on
                        if on { Task { await HealthService.shared.requestAndRefresh() } }
                        else { HealthService.shared.disable() }
                    }
                ))
                .disabled(!HealthService.shared.isAvailable)
            } header: {
                Text("Health")
            } footer: {
                Text(HealthService.shared.isAvailable
                     ? "Leest alleen je dagelijkse stappen — nul werk voor jou, en het voedt de correlaties in Inzicht. Zonder Apple Watch is dit het enige zinvolle dat je iPhone bijhoudt."
                     : "Health is niet beschikbaar op dit toestel.")
            }

            Section("Eigen habits") {
                ForEach(customHabits) { habit in
                    Button { renameHabit = habit; renameText = habit.name } label: {
                        Text(habit.name).foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    habitToDelete = offsets.first.map { customHabits[$0] }
                }
                Button { showAddHabit = true } label: {
                    Label("Habit toevoegen", systemImage: "plus")
                }
            }

            Section {
                NavigationLink {
                    NotificationsSettingsView()
                } label: {
                    LabeledContent {
                        Text(activeNotifs == 0 ? "Uit" : "\(activeNotifs) actief")
                    } label: {
                        Label("Meldingen", systemImage: "bell.badge")
                    }
                }
                NavigationLink {
                    ExerciseLibraryView()
                } label: {
                    Label("Oefeningen", systemImage: "dumbbell")
                }
                Picker(selection: $restSeconds) {
                    Text("Uit").tag(0)
                    Text("1:00").tag(60)
                    Text("1:30").tag(90)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                } label: {
                    Label("Rust-timer", systemImage: "timer")
                }
            } header: {
                Text("Tijdens het trainen")
            } footer: {
                Text("De rust-timer start automatisch na elke afgevinkte set.")
            }

            Section {
                ForEach(scales) { scale in
                    ScaleRow(scale: scale)
                }
                .onDelete { offsets in
                    scaleToDelete = offsets.first.map { scales[$0] }
                }
                Button { showAddScale = true } label: {
                    Label("Weegschaal toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Weegschalen")
            } footer: {
                Text("Kies bij elke meting op welke weegschaal je stond. Toevoegen kan ook direct in het weeg-scherm.")
            }

            if Sync.isConfigured {
                Section {
                    LabeledContent("Account", value: Sync.currentEmail ?? "Anoniem (alleen dit toestel)")
                    Button {
                        showLogin = true
                    } label: {
                        Label(Sync.isAnonymous ? "Account koppelen" : "Ander account", systemImage: "person.badge.key")
                    }
                    if !Sync.isAnonymous {
                        Button(role: .destructive) {
                            confirmLogout = true
                        } label: {
                            Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(busy)
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Account verwijderen", systemImage: "trash")
                    }
                    .disabled(busy)
                } header: {
                    Text("Account")
                } footer: {
                    if Sync.isAnonymous {
                        Text("Koppel een account zodat je data ook op andere toestellen beschikbaar is.")
                    }
                }

                Section {
                    LabeledContent("Automatische sync", value: syncStatus.lastSuccess
                        .map { "Laatst: \($0.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "Nog niet gesynct")
                    if let last = syncStatus.lastSuccess, syncStatus.isStale {
                        Text("Laatst gelukt \(last.formatted(.relative(presentation: .named))). Met verbinding gaat het vanzelf verder; \"Sync nu\" probeert het meteen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error = syncStatus.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    Button {
                        runPush()
                    } label: {
                        if busy { ProgressView() } else { Label("Sync nu", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(busy)
                    Button(role: .destructive) {
                        confirmRestore = true
                    } label: {
                        Label("Data ophalen van server", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(busy)
                    if let backupMessage {
                        Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synchronisatie")
                } footer: {
                    Text("Elke wijziging gaat automatisch naar de server. \"Data ophalen\" vervangt alles op dit toestel door de serverversie — je account raakt nooit iets kwijt.")
                }
            } else {
                Section("Synchronisatie") {
                    Text("Niet geconfigureerd. Vul SUPABASE_URL en SUPABASE_ANON_KEY in Built/Secrets.plist in en draai supabase/schema.sql in je Supabase-project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    syncCalendar()
                } label: {
                    if calBusy { ProgressView() }
                    else { Label("Zet weekplanning in agenda", systemImage: "calendar.badge.plus") }
                }
                .disabled(calBusy)
                if CalendarSync.hasCreatedEvents {
                    Button(role: .destructive) {
                        CalendarSync.removeCreated()
                        calMessage = "Built-events verwijderd."
                    } label: {
                        Label("Verwijder Built-events", systemImage: "calendar.badge.minus")
                    }
                }
                if let calMessage {
                    Text(calMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Agenda")
            } footer: {
                Text("Zet je weekplanning (komende 4 weken) in je iOS-agenda. Staat je Google-account onder Instellingen → Agenda, dan verschijnt het in Google Calendar en synct het twee kanten op.")
            }

            Section("Over") {
                LabeledContent("Versie", value: appVersion)
                if !weights.isEmpty {
                    ShareLink(item: weightCSV, preview: SharePreview("Gewichtsdata (CSV)")) {
                        Label("Exporteer gewichtsdata", systemImage: "square.and.arrow.up")
                    }
                }
                if let json = Sync.exportJSON(context) {
                    ShareLink(item: json, preview: SharePreview("Built-data (JSON)")) {
                        Label("Exporteer alle data (JSON)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Link(destination: URL(string: "mailto:flitsdigital1@gmail.com?subject=Built%20feedback")!) {
                    Label("Feedback sturen", systemImage: "envelope")
                }
            }
        }
        .tabBarClearance()
        .navigationTitle("Profiel")
        .scrollDismissesKeyboard(.interactively)
        .alert("Nieuwe habit", isPresented: $showAddHabit) {
            TextField("bijv. Vitamine D", text: $habitName)
            Button("Toevoegen") {
                let name = habitName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { context.insert(CustomHabit(name: name)) }
                habitName = ""
            }
            Button("Annuleer", role: .cancel) { habitName = "" }
        } message: {
            Text("Komt in je dagelijkse checklist en weekoverzicht. Telt niet mee voor de Groei Score.")
        }
        .alert("Nieuwe weegschaal", isPresented: $showAddScale) {
            TextField("Naam (bijv. Badkamer)", text: $scaleName)
            Button("Toevoegen") {
                let name = scaleName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { context.insert(Scale(name: name)) }
                scaleName = ""
            }
            Button("Annuleer", role: .cancel) { scaleName = "" }
        }
        .confirmationDialog("Habit én alle vinkjes ervan verwijderen?",
                            isPresented: Binding(get: { habitToDelete != nil },
                                                 set: { if !$0 { habitToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \"\(habitToDelete?.name ?? "")\"", role: .destructive) {
                if let habitToDelete { context.delete(habitToDelete) }
                habitToDelete = nil
            }
            Button("Annuleer", role: .cancel) { habitToDelete = nil }
        }
        .confirmationDialog("Weegschaal verwijderen? Bestaande metingen blijven staan.",
                            isPresented: Binding(get: { scaleToDelete != nil },
                                                 set: { if !$0 { scaleToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \"\(scaleToDelete?.name ?? "")\"", role: .destructive) {
                if let scaleToDelete { context.delete(scaleToDelete) }
                scaleToDelete = nil
            }
            Button("Annuleer", role: .cancel) { scaleToDelete = nil }
        }
        .confirmationDialog("Alle lokale data vervangen door de server?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Data ophalen", role: .destructive) { runPull() }
            Button("Annuleer", role: .cancel) {}
        }
        .sheet(isPresented: $showLogin) { AccountLoginSheet() }
        .confirmationDialog("Uitloggen?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Uitloggen, data op dit toestel houden") {
                logout(keepData: true)
            }
            Button("Uitloggen en toestel leegmaken", role: .destructive) {
                logout(keepData: false)
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Je data blijft altijd op je account staan. \"Toestel leegmaken\" verwijdert alleen de lokale kopie.")
        }
        .confirmationDialog("Account definitief verwijderen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Account en alle data verwijderen", role: .destructive) {
                deleteAccount()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit wist je account én al je data (training, voeding, gewicht) permanent van de server en dit toestel. Dit kan niet ongedaan worden gemaakt.")
        }
        .confirmationDialog("Nieuwe fase starten?", isPresented: $confirmNewPhase, titleVisibility: .visible) {
            Button("Herijk startpunt naar nu") {
                profile.startWeight = weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? profile.startWeight
                profile.startDate = .now
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Je startgewicht wordt je huidige gewicht en de startdatum wordt vandaag. Projecties beginnen opnieuw; je metingen en trainingen blijven staan.")
        }
        .alert("Habit hernoemen", isPresented: Binding(get: { renameHabit != nil }, set: { if !$0 { renameHabit = nil } })) {
            TextField("Naam", text: $renameText)
            Button("Opslaan") {
                if let h = renameHabit { renameCustomHabit(h, to: renameText) }
                renameHabit = nil
            }
            Button("Annuleer", role: .cancel) { renameHabit = nil }
        }
    }

    private func renameCustomHabit(_ habit: CustomHabit, to newName: String) {
        let new = newName.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != habit.name else { return }
        let old = habit.name
        habit.name = new
        // HabitLog koppelt op naam → mee-updaten zodat de vinkjes niet losraken.
        let logs = (try? context.fetch(FetchDescriptor<HabitLog>())) ?? []
        for log in logs where log.name == old { log.name = new }
    }

    private func deleteAccount() {
        busy = true
        backupMessage = nil
        Task {
            do {
                try await Sync.deleteAccount(context: context)
            } catch {
                backupMessage = "Verwijderen mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func syncCalendar() {
        calBusy = true
        calMessage = nil
        Task {
            guard await CalendarSync.requestAccess() else {
                calMessage = "Geen agenda-toegang. Zet 'm aan via Instellingen → Built."
                calBusy = false
                return
            }
            do {
                let n = try CalendarSync.sync(profile: profile)
                calMessage = n > 0 ? "\(n) trainingen in je agenda gezet ✓" : "Nog geen weekplanning ingesteld (Training-tab)."
            } catch {
                calMessage = "Mislukt: \(error.localizedDescription)"
            }
            calBusy = false
        }
    }

    private func logout(keepData: Bool) {
        busy = true
        Task {
            await Sync.signOut(context: context, keepLocalData: keepData)
            busy = false
        }
    }

    private func runPush() {
        busy = true
        backupMessage = nil
        Task {
            do {
                try await Sync.push(context)
                backupMessage = "Gesynct ✓"
            } catch {
                backupMessage = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func runPull() {
        busy = true
        backupMessage = nil
        Task {
            do {
                try await Sync.pull(context)
                backupMessage = "Opgehaald ✓"
            } catch {
                backupMessage = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

/// Inloggen of registreren met e-mail + wachtwoord, of doorgaan met Google.
/// Registreren op een toestel met anonieme data converteert het account (data blijft).
struct AccountLoginSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var registering = false
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    private var formValid: Bool {
        email.contains("@") && password.count >= 6
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Modus", selection: $registering) {
                        Text("Inloggen").tag(false)
                        Text("Registreren").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    TextField("jij@voorbeeld.nl", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                    SecureField("Wachtwoord (min. 6 tekens)", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                    Button {
                        submit()
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(registering ? "Maak account" : "Log in")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !formValid)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    if !registering {
                        Button("Wachtwoord vergeten?") { resetPassword() }
                            .font(.footnote)
                            .disabled(busy || !email.contains("@"))
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                } footer: {
                    Text(registering
                         ? "Registreren op dit toestel koppelt je huidige data aan je account."
                         : "Inloggen haalt de data van je account naar dit toestel.")
                }

                Section {
                    Button {
                        google()
                    } label: {
                        Label("Doorgaan met Google", systemImage: "globe")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(busy)
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard registering else {
            run { try await Sync.signIn(email: mail, password: password, context: context) }
            return
        }
        busy = true
        message = nil
        Task {
            do {
                try await Sync.register(email: mail, password: password, context: context)
                if Sync.hasSession {
                    dismiss() // meteen ingelogd (bevestiging staat uit)
                } else {
                    message = "Check je mail om je account te bevestigen, en log daarna in."
                }
            } catch {
                message = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func google() {
        run {
            try await Sync.signInWithGoogle(context: context)
        }
    }

    private func resetPassword() {
        busy = true
        message = nil
        Task {
            do {
                try await Sync.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
                message = "We hebben je een reset-link gemaild (check ook je spam)."
            } catch {
                message = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                message = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

struct NotificationsSettingsView: View {
    @AppStorage("notifMorningOn") private var morningOn = false
    @AppStorage("notifMorningTime") private var morningTime = 8 * 60
    @AppStorage("notifEveningOn") private var eveningOn = false
    @AppStorage("notifEveningTime") private var eveningTime = 20 * 60 + 30
    @AppStorage("notifStreakOn") private var streakOn = true
    @AppStorage("notifWeekOn") private var weekOn = true
    @AppStorage("notifReviewOn") private var reviewOn = true
    @AppStorage("notifRestOn") private var restOn = true
    @AppStorage("notifCheckInOn") private var checkInOn = true

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes.wrappedValue / 60,
                                      minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
            },
            set: {
                let c = Calendar.current
                minutes.wrappedValue = c.component(.hour, from: $0) * 60 + c.component(.minute, from: $0)
            })
    }

    var body: some View {
        List {
            Section {
                Toggle("Ochtend — wegen", isOn: $morningOn)
                if morningOn {
                    DatePicker("Tijd", selection: timeBinding($morningTime), displayedComponents: .hourAndMinute)
                }
                Toggle("Avond — dagcheck", isOn: $eveningOn)
                if eveningOn {
                    DatePicker("Tijd", selection: timeBinding($eveningTime), displayedComponents: .hourAndMinute)
                }
                Toggle("Dag-check-in (21:00)", isOn: $checkInOn)
            } header: {
                Text("Dagelijks")
            } footer: {
                Text("Stil bij succes: al gewogen of dag al binnen → geen melding. De avondcheck vertelt precies wat er nog openstaat, met knoppen om direct te loggen. De check-in vraagt naar energie, stemming, spierpijn en stress — dat voedt je correlaties in Inzicht.")
            }

            Section {
                Toggle("Streak-bescherming", isOn: $streakOn)
                Toggle("Trainingsweek-bewaking", isOn: $weekOn)
            } header: {
                Text("Bescherming")
            } footer: {
                Text("Streak: om 21:30, alleen als je streak ≥ 3 dagen is én de dag nog niet perfect. Trainingsweek: do/vr 17:00, alleen als je achterloopt op je weekdoel.")
            }

            Section {
                Toggle("Week Review (zo 19:00)", isOn: $reviewOn)
                Toggle("Rust-timer klaar", isOn: $restOn)
            } header: {
                Text("Overig")
            } footer: {
                Text("De rust-timer melding komt alleen als de app niet open is — in de app voel je een tik.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Meldingen")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { Notifier.shared.refresh() }
    }
}

struct ScaleRow: View {
    let scale: Scale

    var body: some View {
        Label(scale.name, systemImage: "scalemass")
    }
}
