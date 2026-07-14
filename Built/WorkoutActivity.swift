import ActivityKit
import Foundation

/// Live Activity voor een lopende training: Dynamic Island + lockscreen.
/// Gedeeld tussen app (start/update/end) en widget-extensie (UI).
struct WorkoutActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var restStartedAt: Date?
        var restEndsAt: Date?

        var resting: Bool { restEndsAt.map { $0 > .now } ?? false }
    }

    var startedAt: Date
}
