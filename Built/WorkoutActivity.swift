import ActivityKit
import Foundation

/// Live Activity voor een lopende training: Dynamic Island + lockscreen.
/// Gedeeld tussen app (start/update/end) en widget-extensie (UI).
struct WorkoutActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var restStartedAt: Date?
        var restEndsAt: Date?
        var exercise: String?
        var setsDone = 0
        var setsTotal = 0
        /// Coach-regel, bijv. "Vorige keer: 40 kg × 8 — met 45 kg is 6+ reps een PR"
        var tip: String?
        /// Rust ná de volgende set, in seconden; 0 = geen rust (superset of cardio).
        /// Reist mee met de activity omdat de "Set klaar"-knop in de extensie de rust zelf
        /// moet starten: die kent de rusttijd per oefening van de app niet.
        var restSeconds = 0

        var resting: Bool { restEndsAt.map { $0 > .now } ?? false }
        var setsLeft: Int { max(setsTotal - setsDone, 0) }
    }

    var startedAt: Date
}
