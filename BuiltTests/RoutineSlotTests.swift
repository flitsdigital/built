import Foundation
import SwiftData
import Testing
@testable import Built

/// Dezelfde oefening mag twee keer in een routine staan. Doelen, superset, rust en
/// alternatieven hangen daarom aan de plek en niet aan de naam — en die sleutel moet
/// blijven kloppen als je sleept, verwijdert of hernoemt. Gaat dat mis, dan krijgt je
/// burnout-blok stilletjes de sets van je zware blok.
@Suite("Plekken in een routine")
struct RoutineSlotTests {
    let context: ModelContext

    init() throws {
        context = try memoryContext()
    }

    private func routine(_ exercises: [String]) -> Routine {
        let r = Routine(name: "Push", exercises: exercises)
        context.insert(r)
        return r
    }

    @Test("Zonder dubbele oefeningen is de sleutel gewoon de naam")
    func geenDubbele() {
        let r = routine(["Bench Press", "Shoulder Press", "Dips"])
        #expect(r.slotKeys == ["Bench Press", "Shoulder Press", "Dips"])
    }

    @Test("Een herhaling krijgt een achtervoegsel")
    func herhaling() {
        let r = routine(["Bench Press", "Dips", "Bench Press", "Bench Press"])
        #expect(r.slotKeys == ["Bench Press", "Dips", "Bench Press#2", "Bench Press#3"])
    }

    @Test("Sleutels zijn uniek, ook als een oefening zelf al een achtervoegsel heet")
    func botsendeNaam() {
        let r = routine(["Squat", "Squat", "Squat#2"])
        #expect(r.slotKeys == ["Squat", "Squat#2", "Squat#2#2"])
        #expect(Set(r.slotKeys).count == r.exercises.count)
    }

    @Test("Lege routine heeft geen plekken")
    func leeg() {
        #expect(routine([]).slotKeys.isEmpty)
    }

    @Test("Elke plek houdt z'n eigen doel")
    func doelenPerPlek() {
        let r = routine(["Bench Press", "Bench Press"])
        r.targets["Bench Press"] = [4, 6]
        r.targets["Bench Press#2"] = [2, 15]
        #expect(r.targets[r.slotKeys[0]] == [4, 6])
        #expect(r.targets[r.slotKeys[1]] == [2, 15])
    }

    @Test("Verplaatsen neemt doelen, superset en rust mee")
    func verplaatsen() {
        let r = routine(["Bench Press", "Dips", "Bench Press"])
        r.targets["Bench Press"] = [4, 6]
        r.targets["Bench Press#2"] = [2, 15]
        r.targets["Dips"] = [3, 10]
        r.supersets["Bench Press#2"] = "A"
        r.restByExercise["Bench Press"] = 180

        r.reorderExercises(to: [2, 0, 1]) // burnout-blok naar voren

        #expect(r.exercises == ["Bench Press", "Bench Press", "Dips"])
        // Het blok dat vooraan stond is nu de tweede plek; z'n instellingen zijn mee.
        #expect(r.targets["Bench Press"] == [2, 15])
        #expect(r.targets["Bench Press#2"] == [4, 6])
        #expect(r.targets["Dips"] == [3, 10])
        #expect(r.supersets["Bench Press"] == "A")
        #expect(r.supersets["Bench Press#2"] == nil)
        #expect(r.restByExercise["Bench Press#2"] == 180)
    }

    @Test("Het eerste blok verwijderen laat het tweede z'n eigen doel houden")
    func verwijderen() {
        let r = routine(["Bench Press", "Bench Press", "Dips"])
        r.targets["Bench Press"] = [4, 6]
        r.targets["Bench Press#2"] = [2, 15]
        r.targets["Dips"] = [3, 10]

        r.reorderExercises(to: [1, 2]) // plek 0 valt weg

        #expect(r.exercises == ["Bench Press", "Dips"])
        #expect(r.targets["Bench Press"] == [2, 15])
        #expect(r.targets["Bench Press#2"] == nil)
        #expect(r.targets["Dips"] == [3, 10])
    }

    @Test("Verwijderen ruimt de instellingen van die plek op")
    func verwijderenRuimtOp() {
        let r = routine(["Bench Press", "Dips"])
        r.targets["Dips"] = [3, 10]
        r.alternatives["Dips"] = ["Push Up"]
        r.restByExercise["Dips"] = 90

        r.reorderExercises(to: [0])

        #expect(r.exercises == ["Bench Press"])
        #expect(r.targets.isEmpty)
        #expect(r.alternatives.isEmpty)
        #expect(r.restByExercise.isEmpty)
    }

    @Test("Een onmogelijke volgorde laat de routine met rust")
    func ongeldigeVolgorde() {
        let r = routine(["Bench Press", "Dips"])
        r.targets["Dips"] = [3, 10]

        r.reorderExercises(to: [0, 5])

        #expect(r.exercises == ["Bench Press", "Dips"])
        #expect(r.targets["Dips"] == [3, 10])
    }

    @Test("Hernoemen verhuist alle plekken van die oefening")
    func hernoemen() {
        let r = routine(["Bench Press", "Dips", "Bench Press"])
        r.targets["Bench Press"] = [4, 6]
        r.targets["Bench Press#2"] = [2, 15]
        r.supersets["Dips"] = "A"

        r.renameExercise(from: "Bench Press", to: "Bankdrukken")

        #expect(r.exercises == ["Bankdrukken", "Dips", "Bankdrukken"])
        #expect(r.targets["Bankdrukken"] == [4, 6])
        #expect(r.targets["Bankdrukken#2"] == [2, 15])
        #expect(r.supersets["Dips"] == "A")
    }

    @Test("Hernoemen naar een naam die er al in staat houdt de doelen uit elkaar")
    func hernoemenNaarBestaande() {
        let r = routine(["Bench Press", "Dumbbell Press"])
        r.targets["Bench Press"] = [4, 6]
        r.targets["Dumbbell Press"] = [3, 12]

        r.renameExercise(from: "Dumbbell Press", to: "Bench Press")

        #expect(r.exercises == ["Bench Press", "Bench Press"])
        #expect(r.targets["Bench Press"] == [4, 6])
        #expect(r.targets["Bench Press#2"] == [3, 12])
    }

    @Test("Hernoemen raakt ook een oefening die alleen vervanger is")
    func hernoemenAlsVervanger() {
        let r = routine(["Bench Press"])
        r.alternatives["Bench Press"] = ["Dumbbell Press"]

        r.renameExercise(from: "Dumbbell Press", to: "Halterdrukken")

        #expect(r.exercises == ["Bench Press"])
        #expect(r.alternatives["Bench Press"] == ["Halterdrukken"])
    }
}
