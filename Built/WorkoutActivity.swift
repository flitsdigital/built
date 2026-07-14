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

        var resting: Bool { restEndsAt.map { $0 > .now } ?? false }
        var setsLeft: Int { max(setsTotal - setsDone, 0) }
    }

    var startedAt: Date
}
