import Foundation
import Testing
@testable import Built

/// `ExerciseGuide.swift` is gegenereerd door `scripts/exercises.py`. Deze tests bewaken
/// de aannames waar de rest van de app op leunt — een generator die ze breekt merk je
/// anders pas als er een oefening dubbel in de lijst staat.
@Suite("Oefeningcatalogus")
struct CatalogTests {

    /// Elk toestel zaait de catalogus zelf met `UUID.stable(from: name)`. Twee rijen met
    /// dezelfde naam krijgen dus hetzelfde id, en `Exercise.dedupe` gooit er één weg — met
    /// een tombstone, dus ook op de server.
    @Test("Elke naam komt één keer voor")
    func namenZijnUniek() {
        let namen = ExerciseCatalog.seed.map(\.name)
        #expect(Set(namen).count == namen.count)
    }

    /// De bibliotheek groepeert op `muscle` en de kiezers filteren op `type`; een waarde
    /// buiten de lijst valt uit beeld zonder dat er iets stukgaat.
    @Test("Spier en type staan in de lijsten van de editor")
    func waardenZijnBekend() {
        for row in ExerciseCatalog.seed {
            #expect(Exercise.muscles.contains(row.muscle), "\(row.name): \(row.muscle)")
            #expect(Exercise.types.contains(row.type), "\(row.name): \(row.type)")
        }
    }

    /// De naslag wordt opgezocht op naam. Een sleutel die niet in de catalogus staat is
    /// een oefening die niemand ooit te zien krijgt.
    @Test("Elke naslag hoort bij een oefening uit de catalogus")
    func naslagHoortBijEenOefening() {
        let namen = Set(ExerciseCatalog.seed.map(\.name))
        for naam in ExerciseCatalog.guides.keys {
            #expect(namen.contains(naam), "\(naam)")
        }
    }

    /// Zonder bestand geen plaatje. De map zit niet in git, dus dit valt om op een verse
    /// checkout — één regel met wat je moet draaien, niet 128 losse fouten.
    @Test("Elke naslag heeft z'n plaatje in de bundle")
    func mediaBestaat() {
        let ontbreekt = ExerciseCatalog.guides
            .filter { $0.value.still == nil || ExerciseGuide.gifURL($0.value.media) == nil }
            .keys.sorted()
        #expect(ontbreekt.isEmpty, """
            \(ontbreekt.count) van de \(ExerciseCatalog.guides.count) missen hun beeld \
            (\(ontbreekt.prefix(3).joined(separator: ", "))…). Draai: \
            python3 scripts/exercises.py <pad naar exercises-dataset>
            """)
    }
}
