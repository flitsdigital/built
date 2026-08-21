import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// Een afgeronde training als plaatje. Het deelbericht (`workoutShareText`) blijft
// bestaan — dat is prima voor een appje — maar tekst is niets voor een story, en dit
// is dezelfde inhoud in de vormtaal van de app.
//
// Wat er bewust níét op staat: je lichaamsgewicht. Een plaatje stuur je door aan
// mensen die je logboek nooit te zien krijgen, dus alles wat over jóú gaat in plaats
// van over de training hoort er niet standaard op. Bodyweight-oefeningen tonen daarom
// ook hier alleen de reps ("×8") of het extra gewicht ("+5×8") — precies wat
// `setNotation` al doet — en nooit de last waarmee het volume is gerekend.

/// De inhoud van het deelplaatje. Een `Transferable` en geen kant-en-klare `Image`,
/// zodat het renderen pas gebeurt als er echt gedeeld wordt: de deelknop staat in een
/// scherm dat bij elke aanpassing opnieuw tekent, en daar hoort geen ImageRenderer in.
struct WorkoutShareImage: Transferable {
    /// De naam van de training ("Push A") of gewoon "Training".
    let title: String
    let date: String
    let duration: String
    let volume: Int
    let sets: Int
    let lines: [WorkoutShareLine]
    let prs: [(exercise: String, new: Double, old: Double)]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = await item.png() else { throw RenderFailed() }
            return data
        }
        .suggestedFileName("Built-training.png")
    }

    private struct RenderFailed: Error {}

    @MainActor
    func png() -> Data? {
        // De kaart erft niets van het scherm eromheen, dus de donkere modus staat hier
        // expliciet: een plaatje op een lichte achtergrond verdwijnt in elke tijdlijn.
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .dark))
        renderer.scale = 3 // 360 pt breed → 1080 px, de maat waar Instagram op mikt
        return renderer.uiImage?.pngData()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BUILT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.green)
                Text(title)
                    .font(.title.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                StatTile(value: duration, label: "duur")
                StatTile(value: "\(volume)", label: "kg volume")
                StatTile(value: "\(sets)", label: "sets")
            }
            .builtCard()

            if !lines.isEmpty {
                VStack(spacing: 10) {
                    // Op index, niet op naam: dezelfde oefening kan twee keer in een
                    // training zitten, en dan zou ForEach er één weglaten.
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.exercise)
                                .font(.subheadline.weight(.semibold))
                            Text(line.sets)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .builtCard()
            }

            if !prs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prs, id: \.exercise) { pr in
                        Text("🏆 \(pr.exercise): e1RM \(pr.new.kgText) kg (was \(pr.old.kgText))")
                            .font(.subheadline.bold())
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.builtTint(.yellow), in: RoundedRectangle(cornerRadius: BuiltRadius.medium))
            }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Deelplaatje") {
    let image = WorkoutShareImage(
        title: "Push A",
        date: "maandag 18 augustus",
        duration: "52 min",
        volume: 4320,
        sets: 18,
        lines: [WorkoutShareLine(exercise: "Bench Press", sets: "60×8  60×8  62,5×6"),
                WorkoutShareLine(exercise: "Dips", sets: "×10  +5×8"),
                WorkoutShareLine(exercise: "Lateral Raise", sets: "12×12  12×12")],
        prs: [("Bench Press", 75, 72.5)])
    // Dezelfde weg als bij het delen, zodat de preview laat zien wat er echt uit komt.
    return Image(uiImage: UIImage(data: image.png() ?? Data()) ?? UIImage())
        .resizable()
        .scaledToFit()
        .padding()
}
