import Foundation

/// Gedeeld tussen app en widget: de app schrijft dit als JSON naar de app group,
/// de widget leest het. Geen SwiftData in de widget nodig.
struct WidgetSnapshot: Codable {
    var score: Int
    var protein: Int
    var proteinTarget: Int
    var trained: Bool
    var creatine: Bool
    var weighed: Bool
    var slept: Bool
    var streak: Int
    var showCreatine: Bool? = true
    var showSleep: Bool? = true
    var restDay: Bool? = false
    var showFood: Bool? = true
    /// De app staat op slot. De widget hoort dan niets persoonlijks te tonen: hij staat
    /// op het beginscherm, en daar komt geen Face ID aan te pas. De app schrijft de
    /// cijfers dan ook niet weg — wat er niet in dit bestand staat, kan niet lekken.
    var locked: Bool? = false

    static let appGroup = "group.com.jordiklavers.Built"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url)
    }
}
