import SwiftUI
import SwiftData

/// Instellingen-hub: alleen rijen die ergens heen gaan, met rechts de waarde die er nu
/// staat. De bediening zelf staat één niveau dieper. Alles op één scherm was 13 secties
/// en ~35 rijen — je scrolde langs alinea's uitleg om één toggle te vinden.
struct ProfileView: View {
    @Bindable var profile: Profile
    @Query(sort: \Scale.name) private var scales: [Scale]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]

    // Zelfde keys als NotificationsSettingsView → status-badge blijft live kloppen
    @AppStorage("notifMorningOn") private var notifMorningOn = false
    @AppStorage("notifEveningOn") private var notifEveningOn = false
    @AppStorage("notifStreakOn") private var notifStreakOn = true
    @AppStorage("notifWeekOn") private var notifWeekOn = true
    @AppStorage("notifReviewOn") private var notifReviewOn = true
    @AppStorage("notifRestOn") private var notifRestOn = true
    @AppStorage("notifCheckInOn") private var notifCheckInOn = true

    private let syncStatus = SyncStatus.shared

    private var activeNotifs: Int {
        [notifMorningOn, notifEveningOn, notifStreakOn, notifWeekOn, notifReviewOn, notifRestOn, notifCheckInOn]
            .filter { $0 }.count
    }

    private var activeHabits: Int {
        [profile.tracksCreatine, profile.tracksSleep, profile.tracksFood].filter { $0 }.count + customHabits.count
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// Alleen de kcal: het doelgewicht staat al in de kop erboven, en met beide erin
    /// past de waarde niet naast de titel — dan zet LabeledContent 'm eronder en staat
    /// deze rij scheef tussen de andere.
    private var goalSummary: String {
        let kcal = profile.kcalTarget == 0 ? profile.autoKcal(weights) : profile.kcalTarget
        return "\(kcal.formatted()) kcal"
    }

    private var accountSummary: String {
        guard Sync.isConfigured else { return "Uit" }
        return Sync.currentEmail ?? "Niet ingelogd"
    }

    /// Sync woont op het account-scherm; de hub draagt alleen het waarschuwingsstipje,
    /// zodat een mislukte sync niet onzichtbaar wordt door hem een niveau dieper te zetten.
    private var syncNeedsAttention: Bool {
        Sync.isConfigured && (syncStatus.lastError != nil || syncStatus.isStale)
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
                row("Doel & voeding", "target", value: goalSummary) {
                    GoalSettingsView(profile: profile)
                }
                row("Trainen", "figure.strengthtraining.traditional",
                    value: "\(profile.trainingsPerWeek)×/week") {
                    TrainingSettingsView(profile: profile)
                }
                row("Habits", "checklist", value: "\(activeHabits) actief") {
                    HabitsSettingsView(profile: profile)
                }
                row("Weegschalen", "scalemass", value: "\(scales.count)") {
                    ScalesSettingsView()
                }
            }

            Section {
                row("Meldingen", "bell.badge", value: activeNotifs == 0 ? "Uit" : "\(activeNotifs) actief") {
                    NotificationsSettingsView()
                }
                row("Oefeningen", "dumbbell") {
                    ExerciseLibraryView()
                }
            }

            Section {
                row("Account", "person.crop.circle", value: accountSummary, warn: syncNeedsAttention) {
                    AccountSettingsView()
                }
                row("Over", "info.circle", value: appVersion) {
                    AboutSettingsView()
                }
            }
        }
        .tabBarClearance()
        .navigationTitle("Profiel")
    }

    @ViewBuilder
    private func row<D: View>(_ title: String, _ icon: String, value: String = "", warn: Bool = false,
                              @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    if warn {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Vraagt aandacht")
                    }
                    if !value.isEmpty {
                        Text(value).lineLimit(1).truncationMode(.middle)
                    }
                }
            } label: {
                Label(title, systemImage: icon)
            }
        }
    }
}

// MARK: - Doel & voeding

struct GoalSettingsView: View {
    @Bindable var profile: Profile
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @State private var confirmNewPhase = false

    private var autoKcal: Int { profile.autoKcal(weights) }

    var body: some View {
        List {
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
            } header: {
                Text("Jouw doel")
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
                Button("Nieuwe fase starten") { confirmNewPhase = true }
            } footer: {
                Text("Herijkt je startpunt naar je huidige gewicht en vandaag — handig bij een nieuwe cut of bulk. Je historie blijft staan.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Doel & voeding")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Nieuwe fase starten?", isPresented: $confirmNewPhase, titleVisibility: .visible) {
            Button("Herijk startpunt naar nu") {
                profile.startWeight = weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? profile.startWeight
                profile.startDate = .now
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Je startgewicht wordt je huidige gewicht en de startdatum wordt vandaag. Projecties beginnen opnieuw; je metingen en trainingen blijven staan.")
        }
    }
}

// MARK: - Trainen

/// Trainingsdagen, rust-timer en de agenda-export: alles wat over de week zelf gaat.
struct TrainingSettingsView: View {
    @Bindable var profile: Profile
    @AppStorage("restSeconds") private var restSeconds = 120
    @State private var calMessage: String?
    @State private var calBusy = false

    private let weekdayOptions: [(day: Int, label: String)] = [
        (2, "Ma"), (3, "Di"), (4, "Wo"), (5, "Do"), (6, "Vr"), (7, "Za"), (1, "Zo"),
    ]

    private var trainingDaysSummary: String? {
        let picked = weekdayOptions.filter { profile.trainingDays.contains($0.day) }.map(\.label)
        guard !picked.isEmpty else { return nil }
        return "Gekozen: \(picked.joined(separator: ", "))"
    }

    var body: some View {
        List {
            Section {
                Stepper("Training: \(profile.trainingsPerWeek)×/week", value: $profile.trainingsPerWeek, in: 1...7)
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
                Picker(selection: $restSeconds) {
                    Text("Uit").tag(0)
                    Text("1:00").tag(60)
                    Text("1:30").tag(90)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                } label: {
                    Label("Rust-timer", systemImage: "timer")
                }
            } footer: {
                Text("De rust-timer start automatisch na elke afgevinkte set.")
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
        }
        .tabBarClearance()
        .navigationTitle("Trainen")
        .navigationBarTitleDisplayMode(.inline)
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
                calMessage = "Mislukt: \(Sync.message(for: error))"
            }
            calBusy = false
        }
    }
}

// MARK: - Habits

struct HabitsSettingsView: View {
    @Bindable var profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]
    @AppStorage("healthStepsOn") private var healthOn = false

    @State private var showAddHabit = false
    @State private var habitName = ""
    @State private var renameHabit: CustomHabit?
    @State private var renameText = ""
    @State private var habitToDelete: CustomHabit?

    var body: some View {
        List {
            Section {
                Toggle("Creatine bijhouden", isOn: $profile.tracksCreatine)
                Toggle("Slaap bijhouden", isOn: $profile.tracksSleep)
                Toggle("Eten bijhouden", isOn: $profile.tracksFood)
                if profile.tracksFood {
                    Toggle("Eten telt mee voor je score", isOn: $profile.foodCountsForScore)
                }
            } header: {
                Text("Kern-habits")
            } footer: {
                Text("Je Groei Score telt nu: wegen, training\(profile.foodInScore ? ", eiwit" : "")\(profile.tracksCreatine ? ", creatine" : "")\(profile.tracksSleep ? ", slaap" : ""). Uitgeschakelde habits verdwijnen uit je checklist en tellen niet mee voor streak en perfecte dagen. Eten uit? Dan blijft de Eten-tab gewoon werken, maar staat hij niet meer op je dashboard. Wil je wél blijven loggen zonder dat een vergeten dag je score en streak kost, zet dan alleen \"Eten telt mee voor je score\" uit.")
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
        }
        .tabBarClearance()
        .navigationTitle("Habits")
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("Habit hernoemen", isPresented: Binding(get: { renameHabit != nil }, set: { if !$0 { renameHabit = nil } })) {
            TextField("Naam", text: $renameText)
            Button("Opslaan") {
                if let h = renameHabit { renameCustomHabit(h, to: renameText) }
                renameHabit = nil
            }
            Button("Annuleer", role: .cancel) { renameHabit = nil }
        }
        .confirmationDialog("Habit én alle vinkjes ervan verwijderen?",
                            isPresented: Binding(get: { habitToDelete != nil },
                                                 set: { if !$0 { habitToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \"\(habitToDelete?.name ?? "")\"", role: .destructive) {
                if let habitToDelete { context.deleteSynced(habitToDelete) }
                habitToDelete = nil
            }
            Button("Annuleer", role: .cancel) { habitToDelete = nil }
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
}

// MARK: - Weegschalen

struct ScalesSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Scale.name) private var scales: [Scale]
    @State private var showAddScale = false
    @State private var scaleName = ""
    @State private var scaleToDelete: Scale?

    var body: some View {
        List {
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
            } footer: {
                Text("Kies bij elke meting op welke weegschaal je stond. Toevoegen kan ook direct in het weeg-scherm.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Weegschalen")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Nieuwe weegschaal", isPresented: $showAddScale) {
            TextField("Naam (bijv. Badkamer)", text: $scaleName)
            Button("Toevoegen") {
                let name = scaleName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { context.insert(Scale(name: name)) }
                scaleName = ""
            }
            Button("Annuleer", role: .cancel) { scaleName = "" }
        }
        .confirmationDialog("Weegschaal verwijderen? Bestaande metingen blijven staan.",
                            isPresented: Binding(get: { scaleToDelete != nil },
                                                 set: { if !$0 { scaleToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Verwijder \"\(scaleToDelete?.name ?? "")\"", role: .destructive) {
                if let scaleToDelete { context.deleteSynced(scaleToDelete) }
                scaleToDelete = nil
            }
            Button("Annuleer", role: .cancel) { scaleToDelete = nil }
        }
    }
}

// MARK: - Account

/// Account én sync op één scherm: sync bestáát alleen bij een account, en het enige wat
/// erover te zeggen valt is of het lukt. Destructief staat onderaan, apart.
struct AccountSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var busy = false
    @State private var backupMessage: String?
    @State private var showLogin = false
    @State private var confirmLogout = false
    @State private var confirmDelete = false
    private let syncStatus = SyncStatus.shared

    var body: some View {
        List {
            if Sync.isConfigured {
                Section {
                    LabeledContent("Ingelogd als", value: Sync.currentEmail ?? "Niet ingelogd")
                    Button {
                        showLogin = true
                    } label: {
                        Label("Ander account", systemImage: "person.badge.key")
                    }
                } footer: {
                    if !Sync.hasSession {
                        Text("Niet ingelogd — er gaat niets naar de server. Wat je invoert blijft gewoon op dit toestel staan; log in via \"Ander account\" en alles gaat alsnog mee.")
                    }
                }

                // Geen knoppen. De sync voegt alleen nog samen en heeft dus geen keuze meer
                // voor te leggen — "wie wint" bestaat niet. Wat overblijft is een statusregel:
                // gaat het goed, dan is er niets te doen; gaat het mis, dan staat het hier én
                // op het dashboard (die banner pusht op een tik).
                Section {
                    LabeledContent("Automatische sync", value: syncStatus.lastSuccess
                        .map { "Laatst: \($0.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "Nog niet gesynct")
                    if let pending = syncStatus.pendingSince, syncStatus.isStale {
                        Text("Er staat werk van \(pending.formatted(.relative(presentation: .named))) dat alleen op dit toestel bestaat. Zodra er verbinding is gaat het vanzelf.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let error = syncStatus.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                    if let backupMessage {
                        Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synchronisatie")
                } footer: {
                    Text("Gaat vanzelf: elke wijziging gaat naar de server en wat elders is gebeurd komt hier binnen. Er wordt daarbij nooit iets gewist — beide kanten houden alles.")
                }

                Section {
                    // Uitloggen maakt het toestel leeg. Dat mag alleen als je ook terug kunt
                    // komen, en dat kan precies zolang er een e-mailadres is. Bij een verlopen
                    // sessie is er niets om mee in te loggen, en zou de knop je data
                    // vernietigen zonder weg terug (#42).
                    if Sync.currentEmail != nil {
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
                }
            } else {
                Section("Synchronisatie") {
                    Text("Niet geconfigureerd. Vul SUPABASE_URL en SUPABASE_ANON_KEY in Built/Secrets.plist in en draai supabase/schema.sql in je Supabase-project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tabBarClearance()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) { AccountLoginSheet() }
        .confirmationDialog("Uitloggen?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Uitloggen", role: .destructive) { logout() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Je data blijft op je account staan. Dit toestel wordt leeggemaakt; opnieuw inloggen haalt alles terug.")
        }
        .confirmationDialog("Account definitief verwijderen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Account en alle data verwijderen", role: .destructive) {
                deleteAccount()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit wist je account én al je data (training, voeding, gewicht) permanent van de server en dit toestel. Dit kan niet ongedaan worden gemaakt.")
        }
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

    private func logout() {
        busy = true
        Task {
            await Sync.signOut(context: context)
            busy = false
        }
    }
}

// MARK: - Over

struct AboutSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
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
                LabeledContent("Versie", value: appVersion)
                Link(destination: URL(string: "mailto:flitsdigital1@gmail.com?subject=Built%20feedback")!) {
                    Label("Feedback sturen", systemImage: "envelope")
                }
            }

            Section {
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
            } header: {
                Text("Data")
            }
        }
        .tabBarClearance()
        .navigationTitle("Over")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Profile {
    /// Automatisch calorie-doel op basis van je 7-daags gemiddelde gewicht.
    func autoKcal(_ weights: [WeightEntry]) -> Int {
        autoKcalTarget(currentWeight: weights.average(daysBack: 0..<7) ?? weights.last?.kg ?? startWeight)
    }
}

/// Inloggen of registreren met e-mail + wachtwoord, of doorgaan met Google.
/// Registreren op een toestel met anonieme data converteert het account (data blijft).
/// Alleen inloggen. Registreren gebeurt in de onboarding — dat is de enige plek waar een
/// account ontstaat, dus hier hoort geen tweede route naartoe.
struct AccountLoginSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
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
                    TextField("jij@voorbeeld.nl", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                    SecureField("Wachtwoord", text: $password)
                        .textContentType(.password)
                    Button {
                        run { try await Sync.signIn(email: email.trimmingCharacters(in: .whitespaces),
                                                    password: password, context: context) }
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Log in")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !formValid)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    Button("Wachtwoord vergeten?") { resetPassword() }
                        .font(.footnote)
                        .disabled(busy || !email.contains("@"))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Inloggen haalt de data van je account naar dit toestel.")
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
                message = "Mislukt: \(Sync.message(for: error))"
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
                message = "Mislukt: \(Sync.message(for: error))"
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
