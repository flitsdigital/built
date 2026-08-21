import SwiftUI
import SwiftData

// MARK: - Lezen

/// Eén regel uit een geplakt schema, en wat de app erin herkende.
struct PastedLine {
    /// De regel zoals hij geplakt is. Ook de sleutel van je keuze: er wordt bij elke
    /// toetsaanslag opnieuw gelezen, dus een id per leesbeurt zou je keuze wissen.
    let raw: String
    /// De naam zoals hij in de tekst stond: zonder opsommingsteken en zonder doel.
    let name: String
    /// [sets, reps] als de regel een doel noemde, zoals `Routine.targets` het bewaart.
    let target: [Int]?
    /// Namen uit de catalogus die hierbij kunnen horen, beste eerst. Leeg = niets past.
    let candidates: [String]
    /// Precies één naam, en die is het echt. Anders is het een gok die jij bevestigt.
    let exact: Bool
}

/// Wat er van een geplakt blok tekst te maken viel.
struct PastedRoutine {
    /// De kopregel ("Push A"), of leeg als de tekst er geen had.
    var name: String
    var lines: [PastedLine]
    /// Regels waar geen oefening in zat. Die toon je — stil weggooien is hoe je erachter
    /// komt dat de helft van je schema verdwenen is.
    var unrecognized: [String]
}

/// Een schema uit een boek, een chat of een oude app leest als een routine.
///
/// Bewust dom: een regel is een oefening als er een doel in staat (`3x8`) of als de naam
/// in de catalogus voorkomt. Al het andere blijft staan als onherkend, want een parser die
/// gokt op alles wat op een woord lijkt maakt van "Rust 90 sec" een oefening.
enum RoutineText {
    static func parse(_ text: String, catalogue: [String]) -> PastedRoutine {
        var lines: [PastedLine] = []
        var unrecognized: [String] = []
        var name = ""

        for raw in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (label, target) = splitTarget(stripBullet(trimmed))
            let clean = label.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:·|,."))
                .trimmingCharacters(in: .whitespaces)
            let candidates = match(clean, in: catalogue)
            let isExercise = (target != nil && !clean.isEmpty) || !candidates.isEmpty

            if isExercise {
                lines.append(PastedLine(raw: trimmed, name: clean, target: target,
                                        candidates: candidates,
                                        exact: candidates.count == 1 && normalized(candidates[0]) == normalized(clean)))
            } else if name.isEmpty && lines.isEmpty {
                // De eerste regel vóór de oefeningen is de kop van het schema, niet afval.
                name = trimmed
            } else {
                unrecognized.append(trimmed)
            }
        }
        return PastedRoutine(name: name, lines: lines, unrecognized: unrecognized)
    }

    /// Namen uit de catalogus die bij deze tekst kunnen horen, beste eerst.
    ///
    /// Precies één exacte naam is geen keuze; bij de rest kiest de gebruiker, dus houden we
    /// het bij drie kandidaten. Een menu met tien gokjes is net zo veel werk als opnieuw
    /// zoeken in de kiezer.
    static func match(_ name: String, in catalogue: [String]) -> [String] {
        let key = normalized(name)
        guard !key.isEmpty else { return [] }
        if let exact = catalogue.first(where: { normalized($0) == key }) { return [exact] }
        let near = catalogue.filter { candidate in
            let other = normalized(candidate)
            // Drie letters is de ondergrens: korter en "row" plakt aan elke regel waar het
            // woord toevallig in staat.
            guard other.count >= 3 else { return false }
            return other.contains(key) || key.contains(other)
        }
        return Array(near.sorted { abs($0.count - name.count) < abs($1.count - name.count) }.prefix(3))
    }

    /// Kleine letters, zonder accenten en zonder leestekens: "Kabel-fly" en "kabel fly"
    /// zijn dezelfde oefening.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let letters = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return letters.split(separator: " ").joined(separator: " ")
    }

    /// "1. ", "- ", "• " ervoor weg.
    private static func stripBullet(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, "-–—•*·".contains(first) || first == " " { rest = rest.dropFirst() }
        if let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }),
           rest[rest.startIndex..<dot].allSatisfy(\.isNumber), dot > rest.startIndex {
            rest = rest[rest.index(after: dot)...]
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// Splitst "Kabel fly 2x15" in de naam en [2, 15]. Staat het doel vooraan
    /// ("3x8 Bankdrukken"), dan is de naam wat erachter staat.
    private static func splitTarget(_ line: String) -> (String, [Int]?) {
        guard let hit = line.firstMatch(of: #/(\d{1,2})\s*[xX×*]\s*(\d{1,3})/#),
              let sets = Int(hit.1), let reps = Int(hit.2), sets > 0, reps > 0 else { return (line, nil) }
        let before = String(line[line.startIndex..<hit.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let after = String(line[hit.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (before.isEmpty ? after : before, [sets, reps])
    }
}

// MARK: - Plakken

/// Plak een schema, zie wat de app ervan maakt, en voeg het toe als routine.
///
/// Er is geen "lees dit voor mij"-knop: de tekst wordt gelezen terwijl je 'm plakt. En geen
/// naamveld — de naam komt uit de kopregel en staat op het volgende scherm als titel, waar
/// je 'm toch al aanpast.
struct PasteRoutineSheet: View {
    var onCreate: (Routine) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var text = ""
    /// Regel → gekozen oefeningsnaam. Leeg = deze regel overslaan.
    @State private var choice: [String: String] = [:]
    /// Eén keer lezen per wijziging, niet één keer per rij die opnieuw tekent: bij een
    /// schema van dertig regels tegen de hele catalogus telt dat op.
    @State private var parsed = PastedRoutine(name: "", lines: [], unrecognized: [])

    /// Wat er van deze regel in de routine terechtkomt: jouw keuze, anders de beste match,
    /// anders de naam zoals je 'm plakte — die wordt dan een nieuwe oefening.
    private func resolution(_ line: PastedLine) -> String {
        choice[line.raw] ?? line.candidates.first ?? line.name
    }

    private func isNew(_ name: String) -> Bool {
        !name.isEmpty && !exercises.contains { $0.name == name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 110)
                        .font(.body.monospaced())
                } header: {
                    Text("Plak je schema")
                } footer: {
                    Text("Eén oefening per regel, bijvoorbeeld \u{201C}Bankdrukken 3x8\u{201D}. De regel erboven wordt de naam van de routine.")
                }

                if !parsed.lines.isEmpty {
                    Section {
                        ForEach(Array(parsed.lines.enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    } header: {
                        Text(parsed.name.isEmpty ? "Oefeningen" : parsed.name)
                    } footer: {
                        Text("Tik op een regel om een andere oefening te kiezen of hem over te slaan.")
                    }
                }

                if !parsed.unrecognized.isEmpty {
                    Section {
                        ForEach(Array(parsed.unrecognized.enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Niet herkend")
                    } footer: {
                        Text("Hier zat geen oefening in, dus deze regels komen niet in de routine. Zet er een doel achter (\u{201C}3x8\u{201D}) als het er toch een is.")
                    }
                }
            }
            .onChange(of: text) { _, new in
                parsed = RoutineText.parse(new, catalogue: exercises.map(\.name))
            }
            .navigationTitle("Routine plakken")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Toevoegen") { create() }
                        .disabled(picked.isEmpty)
                }
            }
        }
    }

    /// De namen die straks in de routine staan, in volgorde en zonder dubbele: een naam
    /// die er twee keer in staat breekt de routine-editor, die op naam sorteert en rijt.
    private var picked: [String] {
        var names: [String] = []
        for line in parsed.lines {
            let name = resolution(line)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func row(_ line: PastedLine) -> some View {
        let name = resolution(line)
        let skipped = name.isEmpty
        return Menu {
            ForEach(line.candidates, id: \.self) { candidate in
                Button(candidate) { choice[line.raw] = candidate }
            }
            if !line.name.isEmpty && !line.candidates.contains(line.name) {
                Button("Nieuwe oefening: \(line.name)") { choice[line.raw] = line.name }
            }
            Button("Regel overslaan", role: .destructive) { choice[line.raw] = "" }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skipped ? line.raw : name)
                        .foregroundStyle(skipped ? .secondary : .primary)
                        .strikethrough(skipped)
                    let sub = subtitle(line, name: name)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(line.exact || skipped ? Color.secondary : Color.orange)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ line: PastedLine, name: String) -> String {
        var parts: [String] = []
        if let t = line.target, t.count > 1 { parts.append("\(t[0]) × \(t[1])") }
        if name.isEmpty {
            parts.append("overgeslagen")
        } else if isNew(name) {
            parts.append("nieuwe oefening")
        } else if !line.exact {
            parts.append("gok uit \u{201C}\(line.name)\u{201D}")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func create() {
        var targets: [String: [Int]] = [:]
        for line in parsed.lines {
            let name = resolution(line)
            guard !name.isEmpty, let target = line.target, targets[name] == nil else { continue }
            targets[name] = target
        }
        // Een naam die de catalogus niet kent komt erbij als gewone oefening, net als via
        // "Nieuwe oefening" in de kiezer: sets en routines koppelen op naam, dus zonder
        // die rij bestaat je oefening nergens in de bibliotheek.
        for name in picked where isNew(name) {
            context.insert(Exercise(name: name))
        }
        let routine = Routine(name: parsed.name.isEmpty ? "Geplakte routine" : parsed.name,
                              exercises: picked)
        routine.targets = targets
        context.insert(routine)
        onCreate(routine)
        dismiss()
    }
}
