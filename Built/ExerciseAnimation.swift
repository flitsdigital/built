import SwiftUI
import ImageIO

// MARK: - Bestanden

extension ExerciseGuide {
    /// De stille eerste frame. 6 kB, en er is er altijd één.
    var still: UIImage? { Self.image(media, "jpg") }

    static func image(_ name: String, _ ext: String) -> UIImage? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "ExerciseMedia")
            .flatMap { UIImage(contentsOfFile: $0.path) }
    }

    static func gifURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "ExerciseMedia")
    }
}

// MARK: - Bewegend plaatje

/// De GIF van een oefening, afgespeeld op z'n eigen tempo.
///
/// SwiftUI kent geen GIF, en een `WKWebView` eromheen is een browser opzetten voor een
/// plaatje van 180×180. ImageIO zit in het systeem en geeft de frames los, dus die.
///
/// De frames hebben niet allemaal dezelfde duur — deze GIF's houden boven- en onderkant
/// van de beweging een seconde vast en gaan er in 100 ms tussenin heen. Eén vaste
/// framerate maakt daar een gelijkmatig heen-en-weer van, en dat is precies de informatie
/// die je uit een oefeningplaatje wilt halen. Dus loopt er een tijdlijn mee.
struct ExerciseAnimation: View {
    let guide: ExerciseGuide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [(image: UIImage, end: Double)] = []

    private var total: Double { frames.last?.end ?? 0 }

    var body: some View {
        Group {
            if reduceMotion || frames.count < 2 {
                // Ook de terugval als de GIF ontbreekt: de stille frame staat er altijd.
                if let still = guide.still {
                    Image(uiImage: still).resizable().interpolation(.high)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 25)) { context in
                    Image(uiImage: frame(at: context.date)).resizable().interpolation(.high)
                }
            }
        }
        .scaledToFit()
        // 180×180 is waar de bron ophoudt; groter trekken maakt het alleen zachter.
        .frame(width: 180, height: 180)
        .task { if frames.isEmpty { frames = Self.load(guide.media) } }
        // Een oefening is geen decoratie, maar de beweging valt niet in woorden te vangen.
        .accessibilityHidden(true)
    }

    /// De frame die op dit moment aan de beurt is. De fase van de lus is willekeurig —
    /// er is geen begin dat ergens op slaat, dus is er ook geen startmoment nodig.
    private func frame(at date: Date) -> UIImage {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        return (frames.first { $0.end > t } ?? frames[0]).image
    }

    /// Frames met hun eindpunt op de tijdlijn, oplopend.
    private static func load(_ media: String) -> [(image: UIImage, end: Double)] {
        guard let url = ExerciseGuide.gifURL(media),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var out: [(UIImage, Double)] = []
        var clock = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            clock += delay(source, index)
            out.append((UIImage(cgImage: cg), clock))
        }
        return out
    }

    /// `UnclampedDelayTime` mag 0 zijn — dat is hoe een GIF "zo snel als het kan" zegt.
    /// Browsers maken daar 100 ms van; wij ook, anders staat de lus stil.
    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let value = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        return value > 0.011 ? value : 0.1
    }
}
