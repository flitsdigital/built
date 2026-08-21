import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Historie importeren uit Hevy of Strong.
//
// Beide apps exporteren één CSV met één regel per set. De kolommen heten anders maar
// betekenen hetzelfde, dus er is geen "Hevy-lezer" en geen "Strong-lezer" — er is één
// lezer die kolommen op naam herkent, met een lijstje aliassen per veld. Een derde app
// die dezelfde kolommen exporteert werkt daarmee vanzelf mee.
//
// Twee regels waar dit bestand omheen gebouwd is:
//
// 1. Een import voegt uitsluitend toe. Hij overschrijft geen set, geen trainingsnaam en
//    geen oefening — precies zoals de sync (zie STATUS.md). Wat er al staat blijft staan.
// 2. Elke geïmporteerde rij krijgt een eigen `syncID` (de `SetEntry`-init doet dat), want
//    een van de inhoud afgeleid id zou hier juist verkeerd zijn: drie identieke sets
//    achter elkaar zijn drie rijen, geen één.

// MARK: - Wat er in het bestand staat

/// Eén set uit een geëxporteerde CSV, vertaald naar wat Built ervan bewaart.
///
/// Het gewicht staat er nog in de eenheid van het bestand in. Omrekenen hoort bij het
/// importeren en niet bij het lezen: welke eenheid het is blijkt soms pas uit de kop, en
/// soms helemaal niet — dan kiest de gebruiker.
struct ImportedSet: Equatable {
    var date: Date
    /// De sleutel waarop sets tot één training samenvallen: het tijdstempel van de
    /// training plus z'n naam, precies zoals het in het bestand staat.
    var session: String
    var workoutName: String
    var exercise: String
    var weight: Double
    var reps: Int
    var seconds: Int
    var dropset: Bool
    var failure: Bool
}

/// De eenheid waarin de gewichten in het bestand staan.
enum ImportUnit: String, CaseIterable, Identifiable {
    case kg, lbs
    var id: String { rawValue }
    var label: String { self == .kg ? "kg" : "lb" }
    /// Naar kilo's. De factor is de exacte definitie van de pound, niet 0,4536.
    var toKg: Double { self == .kg ? 1 : 0.453_592_37 }
}

/// Wat er in het bestand zat, vóórdat er iets in de database staat. Zonder deze tussenstap
/// zou "importeren" een knop zijn die je op goed vertrouwen indrukt.
struct ImportPreview {
    var sets: [ImportedSet] = []
    /// Regels die geen set waren: kolomkoppen die ontbraken, een datum die niet te lezen
    /// was, of een rij zonder reps én zonder duur (Strong zet er rustpauzes tussen).
    var ignored = 0
    /// De eenheid zoals de kop hem noemt. `nil` = het bestand zwijgt erover en de
    /// gebruiker moet kiezen; gokken zou een historie van 100 kg-benchpressen opleveren.
    var unit: ImportUnit?

    var sessionCount: Int { Set(sets.map(\.session)).count }

    var period: ClosedRange<Date>? {
        guard let first = sets.map(\.date).min(), let last = sets.map(\.date).max() else { return nil }
        return first...last
    }

    /// Namen die na het matchen nog steeds niet in de bibliotheek staan. Die komen er als
    /// "Overig" bij — net als een oefening die je zelf in een training typt.
    func newExercises(in catalogue: [String]) -> [String] {
        let known = Set(catalogue)
        // Eerst de unieke namen: een export van een jaar heeft duizenden sets en enkele
        // tientallen oefeningen, en matchen kost een reguliere expressie per poging.
        return Set(sets.map(\.exercise))
            .map { HistoryImport.match($0, to: catalogue) }
            .filter { !known.contains($0) }
            .sorted()
    }
}

/// Wat de import gedaan heeft. `skipped` is geen fout maar het vangnet: hetzelfde bestand
/// twee keer kiezen mag je historie niet verdubbelen.
struct ImportResult {
    var added = 0
    var skipped = 0
    var sessions = 0
}

// MARK: - Lezen

enum HistoryImport {

    // MARK: Kolommen

    /// Kolomnamen per veld, in de vorm waarin `normalized` ze oplevert. Hevy schrijft
    /// `exercise_title`, oudere Hevy-exports en Strong `Exercise Name` — dezelfde kolom.
    private static let dateColumns = ["start_time", "date"]
    private static let nameColumns = ["title", "workout_name"]
    private static let exerciseColumns = ["exercise_title", "exercise_name"]
    private static let repsColumns = ["reps"]
    private static let secondsColumns = ["duration_seconds", "seconds"]
    private static let typeColumns = ["set_type"]

    private static func normalized(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    /// Datumnotaties van de exporterende apps. `en_US_POSIX` is geen cosmetica: met de
    /// landinstelling van het toestel leest "22 Jan 2024" niet op een Nederlands toestel.
    private static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss",   // Strong
        "yyyy-MM-dd HH:mm",
        "d MMM yyyy, HH:mm",     // Hevy: "22 Jan 2024, 17:22"
        "d MMM yyyy, HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
    ]

    private static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Een getal uit een cel. Een komma als decimaalteken komt voor bij wie z'n export
    /// door een Europese spreadsheet heeft gehaald.
    private static func number(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Parser

    /// Leest een geëxporteerde CSV. Geeft altijd iets terug: onleesbare regels worden
    /// geteld, niet weggemoffeld en niet fataal — één kapotte regel mag geen jaar
    /// trainingen tegenhouden.
    static func parse(_ text: String) -> ImportPreview {
        var preview = ImportPreview()
        let rows = fields(text)
        guard let header = rows.first else { return preview }
        let columns = header.map(normalized)

        func index(_ names: [String]) -> Int? {
            names.lazy.compactMap { columns.firstIndex(of: $0) }.first
        }
        // Gewicht op prefix, want Strong zet de eenheid in de kop: "Weight (kg)".
        let weightColumn = columns.firstIndex { $0.hasPrefix("weight") }

        guard let dateColumn = index(dateColumns),
              let exerciseColumn = index(exerciseColumns) else {
            preview.ignored = max(rows.count - 1, 0)
            return preview
        }
        let nameColumn = index(nameColumns)
        let repsColumn = index(repsColumns)
        let secondsColumn = index(secondsColumns)
        let typeColumn = index(typeColumns)

        // De eenheid uit de kop. `weight_kg` (Hevy) en `Weight (lbs)` (Strong) zeggen het
        // allebei; een kale `Weight` niet, en dan blijft dit nil.
        if let weightColumn {
            let name = columns[weightColumn]
            if name.contains("kg") { preview.unit = .kg }
            else if name.contains("lb") { preview.unit = .lbs }
        }

        for row in rows.dropFirst() {
            func cell(_ column: Int?) -> String {
                guard let column, column < row.count else { return "" }
                return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let exercise = cell(exerciseColumn)
            let reps = Int(cell(repsColumn)) ?? 0
            let seconds = Int(number(cell(secondsColumn)) ?? 0)
            // Zonder reps én zonder duur valt er niets te loggen: dat is een rustpauze,
            // een losse notitie of een lege regel aan het einde van het bestand.
            guard let date = parseDate(cell(dateColumn)), !exercise.isEmpty,
                  reps > 0 || seconds > 0 else {
                preview.ignored += 1
                continue
            }
            let type = cell(typeColumn).lowercased()
            let name = cell(nameColumn)
            preview.sets.append(ImportedSet(
                date: date,
                session: "\(cell(dateColumn))|\(name)",
                workoutName: name,
                exercise: exercise,
                weight: number(cell(weightColumn)) ?? 0,
                reps: reps,
                seconds: seconds,
                dropset: type.contains("drop"),
                failure: type.contains("fail")))
        }
        return preview
    }

    /// Splitst CSV in regels van velden, met aanhalingstekens erin verwerkt.
    ///
    /// Geen `split(separator: ",")`: een geëxporteerde trainingsnotitie bevat komma's en
    /// zelfs regeleindes, en die staan tussen aanhalingstekens. Zonder dit schuift zo'n
    /// notitie alle kolommen erachter een plek op en importeer je reps als gewicht.
    static func fields(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        // Een `"` binnen een veld tussen aanhalingstekens is óf het einde ervan, óf de
        // eerste helft van een verdubbeld aanhalingsteken. Dat weet je pas bij het
        // volgende teken, dus onthouden we het in plaats van vooruit te kijken.
        var pendingQuote = false

        for character in text {
            if pendingQuote {
                pendingQuote = false
                if character == "\"" { field.append("\""); continue }
                quoted = false
            } else if quoted {
                if character == "\"" { pendingQuote = true } else { field.append(character) }
                continue
            }
            switch character {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\r": break
            case "\n": row.append(field); field = ""; rows.append(row); row = []
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { line in line.contains { !$0.isEmpty } }
    }

    // MARK: Oefeningen matchen

    /// De naam waaronder deze oefening in Built hoort te staan.
    ///
    /// Hevy zet het materiaal tussen haakjes achter de naam ("Bench Press (Barbell)"),
    /// Built niet. Zonder deze normalisatie staat je bibliotheek na een import vol met
    /// tweelingen en telt je vordering per oefening niet door — die koppelt op naam.
    /// Wat ook zo niet matcht komt er als nieuwe oefening bij; dat is wat de app al doet
    /// met een naam die je zelf in een training typt.
    static func match(_ name: String, to catalogue: [String]) -> String {
        let plain = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !plain.isEmpty else { return name }
        // Eerst letterlijk. Anders zou een bibliotheek met zowel "Zercher Squat" als
        // "Zercher Squat (Barbell)" erin de naam laten afhangen van de volgorde van de
        // lijst — en dan matcht dezelfde import twee keer anders.
        if let exact = catalogue.first(where: { $0.lowercased() == plain }) { return exact }
        func key(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        let target = key(name)
        return catalogue.first { key($0) == target } ?? name
    }

    // MARK: Wegschrijven

    /// De vingerafdruk waarop een set als "staat er al" telt. Bewust de kalenderdag en
    /// niet het tijdstip: een geïmporteerd tijdstempel is dat van de hele training, en dat
    /// van een set die je in Built logde is dat van dat ene moment.
    private static func fingerprint(day: Int, exercise: String, kg: Double, reps: Int, seconds: Int) -> String {
        "\(day)|\(exercise.lowercased())|\(String(format: "%.2f", kg))|\(reps)|\(seconds)"
    }

    /// Zet de gelezen sets in de store.
    ///
    /// Toevoegen, nooit overschrijven: een set die er al staat wordt overgeslagen in plaats
    /// van bijgewerkt, en er wordt geen bestaande rij aangeraakt.
    /// Het overslaan telt per stuk mee — drie keer 60 kg × 8 op één dag zijn drie sets, en
    /// alleen als er al drie staan is de vierde een duplicaat. Zo verdubbelt hetzelfde
    /// bestand twee keer kiezen je historie niet, en verliest een tweede export met nieuwe
    /// trainingen erin niets.
    @MainActor
    @discardableResult
    static func apply(_ sets: [ImportedSet], unit: ImportUnit, to context: ModelContext) -> ImportResult {
        var result = ImportResult()
        guard !sets.isEmpty else { return result }

        var existing: [String: Int] = [:]
        for entry in (try? context.fetch(FetchDescriptor<SetEntry>())) ?? [] {
            let key = fingerprint(day: dayKey(entry.date), exercise: entry.exercise,
                                  kg: entry.weightKg, reps: entry.reps, seconds: entry.seconds)
            existing[key, default: 0] += 1
        }

        // De bibliotheek zoals hij nu is. Die staat er al: `Exercise.bootstrap` draait bij
        // elke start, dus ook op een verse installatie is de standaardcatalogus er vóór
        // iemand hier terecht kan komen.
        let catalogue = ((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map(\.name)
        // Eén keer per naam matchen, niet één keer per set: het is dezelfde uitkomst en
        // een export van een jaar heeft duizenden sets over enkele tientallen oefeningen.
        var matched: [String: String] = [:]
        for name in Set(sets.map(\.exercise)) { matched[name] = match(name, to: catalogue) }

        var sessionIDs: [String: UUID] = [:]
        var offsets: [String: Int] = [:]
        // Naam en datum per sessie, om ná het invoegen de trainingsnamen te zetten —
        // `habits(on:)` scant de hele dagtabel, dus dat mag één keer per training en niet
        // één keer per set.
        var sessionInfo: [String: (date: Date, name: String)] = [:]

        for row in sets.sorted(by: { $0.date < $1.date }) {
            let exercise = matched[row.exercise] ?? row.exercise
            let kg = (row.weight * unit.toKg * 100).rounded() / 100
            let key = fingerprint(day: dayKey(row.date), exercise: exercise,
                                  kg: kg, reps: row.reps, seconds: row.seconds)
            if let count = existing[key], count > 0 {
                existing[key] = count - 1
                result.skipped += 1
                continue
            }
            let session = sessionIDs[row.session] ?? UUID()
            sessionIDs[row.session] = session
            if sessionInfo[row.session] == nil {
                sessionInfo[row.session] = (row.date, row.workoutName)
            }
            // Het bestand geeft één tijdstempel voor de hele training. Zonder deze
            // seconde-per-set staan alle sets op exact hetzelfde moment, en dan is de
            // volgorde binnen de training willekeurig — `sorted(by: date)` is niet stabiel.
            let offset = offsets[row.session, default: 0]
            offsets[row.session] = offset + 1
            context.insert(SetEntry(date: row.date.addingTimeInterval(Double(offset)),
                                    exercise: exercise, weightKg: kg, reps: row.reps,
                                    dropset: row.dropset, failure: row.failure,
                                    seconds: row.seconds, workoutID: session))
            result.added += 1
        }
        result.sessions = sessionIDs.count

        // Naam van de training erbij. Dit kan geen naam overschrijven: de sleutel is het
        // zojuist gemaakte sessie-id, en daar hangt per definitie nog niets aan. De
        // trainingen die je zelf in Built logde hebben hun eigen id en blijven met rust.
        for (key, info) in sessionInfo where !info.name.isEmpty {
            guard let session = sessionIDs[key] else { continue }
            context.habits(on: info.date).workoutNames[session.uuidString] = info.name
        }

        // Namen die de bibliotheek nog niet kende erbij zetten als "Overig". Dat is precies
        // wat `bootstrap` al doet voor vrije-tekst-oefeningen uit de historie.
        Exercise.bootstrap(context)
        try? context.save()
        return result
    }
}

// MARK: - Scherm

/// Kies een bestand, kijk wat erin zit, voeg het toe. De tussenstap is het punt: een
/// import is onomkeerbaar zonder dat er een "ongedaan maken" bestaat, dus zie je eerst
/// hoeveel trainingen, over welke periode, en welke oefeningen er nieuw bij komen.
struct HistoryImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var exercises: [Exercise]

    @State private var picking = false
    @State private var preview: ImportPreview?
    @State private var unit: ImportUnit = .kg
    @State private var result: ImportResult?
    @State private var error: String?

    private var catalogue: [String] { exercises.map(\.name) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result {
                    doneCard(result)
                } else if let preview {
                    previewCards(preview)
                } else {
                    explanationCard
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .builtCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { action }
        .tabBarClearance()
        .navigationTitle("Importeren")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText]) { outcome in
            switch outcome {
            case .success(let url): read(url)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    // MARK: Kaarten

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hevy", systemImage: "square.and.arrow.down")
                .font(.subheadline.bold())
            Text("Instellingen → Export & import → Export workout data. Je krijgt de CSV per e-mail.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Label("Strong", systemImage: "square.and.arrow.down")
                .font(.subheadline.bold())
            Text("Profile → Settings → Export Strong data. Bewaar het bestand in Bestanden.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Text("Je bestaande trainingen blijven staan — een import voegt alleen toe, en sets die er al staan slaat hij over.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .builtCard()
    }

    @ViewBuilder
    private func previewCards(_ preview: ImportPreview) -> some View {
        let new = preview.newExercises(in: catalogue)

        VStack(spacing: 12) {
            HStack {
                StatTile(value: "\(preview.sessionCount)", label: "trainingen")
                StatTile(value: "\(preview.sets.count)", label: "sets")
                StatTile(value: "\(new.count)", label: "nieuwe oefeningen")
            }
            if let period = preview.period {
                Divider()
                Text("\(period.lowerBound.formatted(.dateTime.day().month().year())) – \(period.upperBound.formatted(.dateTime.day().month().year()))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .builtCard()

        // Alleen als het bestand de eenheid niet noemt. Het is geen instelling maar een
        // ontbrekend gegeven: Strong exporteert een kolom "Weight" zonder erbij te zeggen
        // waarin, en 100 lb als 100 kg importeren maakt van je historie een fabel.
        if preview.unit == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Het bestand zegt niet in welke eenheid de gewichten staan.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Eenheid", selection: $unit) {
                    ForEach(ImportUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .builtCard()
        }

        if !new.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                BuiltSectionHeader("Komen erbij in je bibliotheek")
                Text(new.prefix(12).joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if new.count > 12 {
                    Text("en nog \(new.count - 12)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .builtCard()
        }

        if preview.ignored > 0 {
            BuiltFootnote("\(preview.ignored) regels overgeslagen: geen set, of een datum die niet te lezen was.")
        }
        if preview.sets.isEmpty {
            BuiltFootnote("Geen sets gevonden. Klopt het dat dit de export van Hevy of Strong is?")
        }
    }

    private func doneCard(_ result: ImportResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                StatTile(value: "\(result.sessions)", label: "trainingen")
                StatTile(value: "\(result.added)", label: "sets erbij", tint: .green)
            }
            if result.skipped > 0 {
                Divider()
                Text("\(result.skipped) sets stonden er al en zijn overgeslagen.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .builtCard()
    }

    // MARK: Actie

    @ViewBuilder
    private var action: some View {
        if result != nil {
            Button("Klaar") { dismiss() }
                .buttonStyle(.borderedProminent).tint(.green)
                .frame(maxWidth: .infinity)
                .builtBottomAction()
        } else if let preview, !preview.sets.isEmpty {
            VStack(spacing: 8) {
                Button("Voeg \(preview.sessionCount) trainingen toe") {
                    result = HistoryImport.apply(preview.sets, unit: preview.unit ?? unit, to: context)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .frame(maxWidth: .infinity)
                Button("Ander bestand") { picking = true }
                    .font(.footnote)
            }
            .builtBottomAction()
        } else {
            Button("Kies CSV-bestand") { picking = true }
                .buttonStyle(.borderedProminent).tint(.green)
                .frame(maxWidth: .infinity)
                .builtBottomAction()
        }
    }

    private func read(_ url: URL) {
        error = nil
        // Het bestand komt uit een andere app: zonder deze twee regels weigert de sandbox
        // het te openen, en zonder de stop lekt de toegang.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            error = "Dat bestand kon ik niet lezen."
            return
        }
        preview = HistoryImport.parse(text)
    }
}
