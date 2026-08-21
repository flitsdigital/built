import Foundation
import Testing
@testable import Built

/// Een gedeelde routine reist zonder server: alles zit in de link. Dan is de link zelf het
/// formaat, en moet wat eruit komt precies zijn wat erin ging — ook als iemand ermee knoeit.
@Suite("Routine delen")
struct RoutineShareTests {

    /// Een routine zoals je 'm in de editor zou opbouwen: doelen, een superset, een
    /// afwijkende rusttijd en een alternatief.
    private func pushDag() -> Routine {
        let routine = Routine(name: "Push A", exercises: ["Bench Press", "Shoulder Press", "Dips"])
        routine.targets = ["Bench Press": [4, 6], "Shoulder Press": [3, 10], "Dips": [3, 12]]
        routine.supersets = ["Shoulder Press": "A", "Dips": "A"]
        routine.restByExercise = ["Bench Press": 180]
        routine.alternatives = ["Bench Press": ["Dumbbell Press", "Push Up"]]
        return routine
    }

    @Test("Alles komt er aan de andere kant weer uit")
    func heenEnTerug() throws {
        let routine = pushDag()
        let terug = try #require(SharedRoutine(url: SharedRoutine(routine).url))

        #expect(terug.name == "Push A")
        #expect(terug.exercises == ["Bench Press", "Shoulder Press", "Dips"])
        #expect(terug.targets == routine.targets)
        #expect(terug.supersets == routine.supersets)
        #expect(terug.restByExercise == routine.restByExercise)
        #expect(terug.alternatives == routine.alternatives)
    }

    /// De volgorde is de routine: eerst zwaar, dan de superset. Een dictionary-roundtrip
    /// die de lijst hersorteert zou dat stil kapotmaken.
    @Test("De volgorde blijft staan, ook bij dezelfde oefening twee keer")
    func volgorde() throws {
        let routine = Routine(name: "Vreemd", exercises: ["Squat", "Plank", "Squat"])
        let terug = try #require(SharedRoutine(url: SharedRoutine(routine).url))
        #expect(terug.exercises == ["Squat", "Plank", "Squat"])
    }

    /// Het `syncID` mag niet mee: dezelfde rij-id onder een ander account botst op de
    /// primary key, en dan pusht de ontvanger nooit meer (zie STATUS.md).
    @Test("Het id van de afzender reist niet mee")
    func geenSyncID() throws {
        let routine = pushDag()
        let link = SharedRoutine(routine).url.absoluteString
        #expect(!link.contains(routine.syncID.uuidString))
        let json = try #require(String(data: JSONEncoder().encode(SharedRoutine(routine)), encoding: .utf8))
        #expect(!json.lowercased().contains(routine.syncID.uuidString.lowercased()))
    }

    /// De link gaat door een chat: alleen tekens die daar heelhuids doorheen komen.
    @Test("De link is een built://routine-link zonder rare tekens")
    func vormVanDeLink() {
        let link = SharedRoutine(pushDag()).url.absoluteString
        #expect(link.hasPrefix("built://routine?r="))
        let payload = link.dropFirst("built://routine?r=".count)
        let toegestaan = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        #expect(payload.unicodeScalars.allSatisfy { toegestaan.contains($0) })
    }

    /// Comprimeren is het antwoord op de vraag uit #59: geen server, maar ook geen link
    /// die drie schermen lang is. Een routine noemt elke naam meerdere keren, en dat is
    /// precies waar zlib van leeft.
    @Test("Comprimeren scheelt echt iets bij een lange routine")
    func comprimeren() throws {
        let namen = ["Bench Press", "Incline Dumbbell Press", "Chest Fly", "Triceps Pushdown",
                     "Lateral Raises", "Shoulder Press", "Dips", "Face Pulls", "Push Up", "Crunch"]
        let routine = Routine(name: "Push volledig", exercises: namen)
        routine.targets = Dictionary(uniqueKeysWithValues: namen.map { ($0, [3, 10]) })
        routine.restByExercise = Dictionary(uniqueKeysWithValues: namen.map { ($0, 90) })

        let shared = SharedRoutine(routine)
        let ruw = try JSONEncoder().encode(shared).base64URLEncoded.count
        let link = shared.url.absoluteString.count
        // 776 tekens onverpakt tegen 332 verpakt: ruim de helft eraf.
        #expect(link < ruw / 2)
    }

    @Test("Een link die geen routine is levert niets op")
    func onzin() {
        #expect(SharedRoutine(url: URL(string: "built://training")!) == nil)
        #expect(SharedRoutine(url: URL(string: "https://example.com/routine?r=abc")!) == nil)
        #expect(SharedRoutine(url: URL(string: "built://routine")!) == nil)
        #expect(SharedRoutine(url: URL(string: "built://routine?r=")!) == nil)
        // Geldige base64url, maar geen routine erin.
        #expect(SharedRoutine(url: URL(string: "built://routine?r=aGFsbG8")!) == nil)
        // Halverwege afgeknipte payload — precies wat een chat met een lange link doet.
        let heel = SharedRoutine(pushDag()).url.absoluteString
        #expect(SharedRoutine(url: URL(string: String(heel.dropLast(12)))!) == nil)
    }

    /// Een routine zonder oefeningen is geen routine; die hoort niet als preview te openen.
    @Test("Een lege routine levert geen link op die iets toevoegt")
    func leeg() {
        let leeg = SharedRoutine(Routine(name: "Nog niets"))
        #expect(SharedRoutine(url: leeg.url) == nil)
    }

    /// Wat je meestuurt voor wie de app niet heeft: dezelfde routine, gewoon leesbaar.
    @Test("De meegestuurde tekst leest als de routine zelf")
    func tekst() {
        let routine = Routine(name: "Cardio", exercises: ["Hardlopen", "Plank"])
        routine.targets = ["Hardlopen": [1, 20], "Plank": [3, 60]]
        let tekst = SharedRoutine(routine).shareText { $0 == "Hardlopen" }
        #expect(tekst == "Cardio\n• Hardlopen — 20 min\n• Plank — 3 × 60")
    }

    @Test("De ondertitel noemt doel, superset en alternatief")
    func ondertitel() {
        let shared = SharedRoutine(pushDag())
        #expect(shared.subtitle(for: "Bench Press", isCardio: false) == "4 × 6  ·  Alt: Dumbbell Press, Push Up")
        #expect(shared.subtitle(for: "Dips", isCardio: false) == "3 × 12  ·  Superset A")
        #expect(shared.subtitle(for: "Hardlopen", isCardio: true) == "")
    }

    @Test("Het totaal telt de doelsets, met drie als terugval")
    func totaal() {
        #expect(SharedRoutine(pushDag()).totals == "3 oefeningen · 10 sets")
        #expect(SharedRoutine(Routine(name: "Kaal", exercises: ["Squat"])).totals == "1 oefening · 3 sets")
    }
}
