import SwiftUI
import SwiftData

struct ProfileView: View {
    @Bindable var profile: Profile
    @Environment(\.modelContext) private var context
    @Query(sort: \Scale.name) private var scales: [Scale]
    @Query(sort: \CustomHabit.createdAt) private var customHabits: [CustomHabit]

    @AppStorage("restSeconds") private var restSeconds = 120
    @AppStorage("lastSync") private var lastBackup = 0.0

    @State private var showAddScale = false
    @State private var scaleName = ""
    @State private var showAddHabit = false
    @State private var habitName = ""
    @State private var busy = false
    @State private var backupMessage: String?
    @State private var confirmRestore = false
    @State private var showLogin = false
    private let syncStatus = SyncStatus.shared

    private let weekdayOptions: [(day: Int, label: String)] = [
        (2, "Ma"), (3, "Di"), (4, "Wo"), (5, "Do"), (6, "Vr"), (7, "Za"), (1, "Zo"),
    ]

    var body: some View {
        List {
            Section("Jouw doel") {
                LabeledContent("Naam") {
                    TextField("Naam", text: $profile.name).multilineTextAlignment(.trailing)
                }
                LabeledContent("Doelgewicht") {
                    TextField("kg", value: $profile.goalWeight, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                DatePicker("Deadline", selection: $profile.goalDate, in: Date.now..., displayedComponents: .date)
                Stepper("Training: \(profile.trainingsPerWeek)×/week", value: $profile.trainingsPerWeek, in: 1...7)
                LabeledContent("Eiwitdoel", value: "\(profile.proteinTarget) g/dag")
                LabeledContent("Tempo", value: "\(profile.weeklyRate >= 0 ? "+" : "")\(profile.weeklyRate.formatted(.number.precision(.fractionLength(2)))) kg/week")
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
                Text("Optioneel. Met vaste dagen telt \"rustdag volgens plan\" mee als perfect, en herinneren meldingen je alleen op trainingsdagen.")
            }

            Section {
                Toggle("Creatine bijhouden", isOn: $profile.tracksCreatine)
                Toggle("Slaap bijhouden", isOn: $profile.tracksSleep)
            } header: {
                Text("Kern-habits")
            } footer: {
                Text("Uitgeschakelde habits verdwijnen uit je checklist en tellen niet mee voor je score, streak en perfecte dagen.")
            }

            Section {
                NavigationLink {
                    NotificationsSettingsView()
                } label: {
                    Label("Meldingen", systemImage: "bell.badge")
                }
            }

            Section("Rust-timer") {
                Picker("Na elke set", selection: $restSeconds) {
                    Text("Uit").tag(0)
                    Text("1:00").tag(60)
                    Text("1:30").tag(90)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                }
            }

            Section("Eigen habits") {
                ForEach(customHabits) { habit in
                    Text(habit.name)
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(customHabits[i]) }
                }
                Button { showAddHabit = true } label: {
                    Label("Habit toevoegen", systemImage: "plus")
                }
            }

            Section {
                ForEach(scales) { scale in
                    ScaleRow(scale: scale)
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(scales[i]) }
                }
                Button { showAddScale = true } label: {
                    Label("Weegschaal toevoegen", systemImage: "plus")
                }
            } header: {
                Text("Weegschalen")
            } footer: {
                Text("Correctie wordt verrekend bij het opslaan van nieuwe metingen. Weegt je weegschaal 0,3 kg te zwaar, zet de correctie dan op -0,3.")
            }

            Section {
                if Sync.isConfigured {
                    LabeledContent("Account", value: Sync.currentEmail ?? "Anoniem (alleen dit toestel)")
                    Button {
                        showLogin = true
                    } label: {
                        Label(Sync.isAnonymous ? "E-mail koppelen" : "Ander account", systemImage: "person.badge.key")
                    }
                    LabeledContent("Automatische sync", value: lastBackup > 0
                        ? "Laatst: \(Date(timeIntervalSinceReferenceDate: lastBackup).formatted(date: .abbreviated, time: .shortened))"
                        : "Nog niet gesynct")
                    if let error = syncStatus.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
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
                } else {
                    Text("Niet geconfigureerd. Vul SUPABASE_URL en SUPABASE_ANON_KEY in Built/Secrets.plist in en draai supabase/schema.sql in je Supabase-project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Supabase")
            } footer: {
                Text("Elke wijziging wordt automatisch naar Supabase gesynct. \"Data ophalen\" vervangt alles op dit toestel door wat er op de server staat.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Profiel")
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
        .confirmationDialog("Alle lokale data vervangen door de server?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Data ophalen", role: .destructive) { runPull() }
            Button("Annuleer", role: .cancel) {}
        }
        .sheet(isPresented: $showLogin) { AccountLoginSheet() }
    }

    private func runPush() {
        busy = true
        backupMessage = nil
        Task {
            do {
                try await Sync.push(context)
                lastBackup = Date.now.timeIntervalSinceReferenceDate
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

/// E-mail koppelen (anoniem → vast account) of inloggen op een bestaand account.
/// Codeflow zonder deep links: Supabase mailt een 6-cijferige code.
struct AccountLoginSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("jij@voorbeeld.nl", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        send()
                    } label: {
                        if busy && !codeSent { ProgressView() } else { Text(codeSent ? "Stuur opnieuw" : "Stuur code") }
                    }
                    .disabled(busy || !email.contains("@"))
                } footer: {
                    Text("Op dit toestel: koppelt je e-mail aan je huidige data. Op een nieuw toestel: log in met hetzelfde adres en je data komt terug.")
                }
                if codeSent {
                    Section {
                        TextField("Code uit de e-mail", text: $code)
                            .keyboardType(.numberPad)
                        Button {
                            verify()
                        } label: {
                            if busy { ProgressView() } else { Text("Bevestig") }
                        }
                        .disabled(busy || code.count < 6)
                    }
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
        .presentationDetents([.medium])
    }

    private func send() {
        busy = true
        message = nil
        Task {
            do {
                try await Sync.sendLoginCode(to: email.trimmingCharacters(in: .whitespaces))
                codeSent = true
                message = "Code verstuurd — check je mail (ook spam)."
            } catch {
                message = "Mislukt: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func verify() {
        busy = true
        message = nil
        Task {
            do {
                try await Sync.verifyLoginCode(email: email.trimmingCharacters(in: .whitespaces),
                                               code: code.trimmingCharacters(in: .whitespaces),
                                               context: context)
                message = "Gelukt ✓"
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
            } header: {
                Text("Dagelijks")
            } footer: {
                Text("Stil bij succes: al gewogen of dag al binnen → geen melding. De avondcheck vertelt precies wat er nog openstaat, met knoppen om direct te loggen.")
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
    @Bindable var scale: Scale

    var body: some View {
        LabeledContent(scale.name) {
            HStack(spacing: 4) {
                Text("correctie")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("0", value: Binding(
                    get: { scale.offset },
                    set: { scale.offset = min(5, max(-5, $0)) } // ponytail: clamp — typo's van -50 kg vervuilen anders alles
                ), format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("kg")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
