import SwiftUI

// MARK: - Kleuren

/// Data-kleuren. Groen blijft het merk-accent; deze coderen alléén data.
/// Eiwit = groen (de held), koolhydraten = oranje, vet = indigo.
extension Color {
    static let macroProtein = Color.green
    static let macroCarbs = Color.orange
    static let macroFat = Color.indigo

    /// Groen-intensiteit voor de body-map: meer volume = voller groen op een grijze basis.
    static func muscleTint(_ value: Double) -> Color {
        let v = min(max(value, 0), 1)
        return v <= 0.001 ? Color(.tertiarySystemFill) : Color.green.opacity(0.22 + 0.6 * v)
    }
}

// MARK: - Kaart

/// Eén kaart-stijl voor de hele app (zelfde als het dashboard).
struct BuiltCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func builtCard(padding: CGFloat = 16) -> some View { modifier(BuiltCard(padding: padding)) }
}

// MARK: - Ring

/// Herbruikbare voortgangsring. Vult smooth (spring), start nooit vanuit niets.
struct ProgressRing<Center: View>: View {
    var value: Double            // 0…1
    var lineWidth: CGFloat = 10
    var tint: AnyShapeStyle = AnyShapeStyle(.green)
    var track: Color = Color(.tertiarySystemFill)
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(value, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: value)
            center()
        }
    }
}

extension ProgressRing where Center == EmptyView {
    init(value: Double, lineWidth: CGFloat = 10, tint: AnyShapeStyle = AnyShapeStyle(.green), track: Color = Color(.tertiarySystemFill)) {
        self.init(value: value, lineWidth: lineWidth, tint: tint, track: track) { EmptyView() }
    }
}

// MARK: - Macro-ring-trio

/// Eiwit groot, koolhydraten en vet klein ernaast (Yazio-patroon).
struct MacroRings: View {
    var protein: Int
    var proteinTarget: Int
    var carbs: Int
    var fat: Int

    var body: some View {
        HStack(spacing: 18) {
            ProgressRing(value: Double(protein) / Double(max(proteinTarget, 1)),
                         lineWidth: 10, tint: AnyShapeStyle(Color.macroProtein)) {
                VStack(spacing: 0) {
                    Text("\(protein)").font(.title3.bold().monospacedDigit())
                    Text("van \(proteinTarget)g").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Eiwit")
            .accessibilityValue("\(protein) van \(proteinTarget) gram")

            VStack(spacing: 10) {
                macroMini("Koolh.", carbs, .macroCarbs)
                macroMini("Vet", fat, .macroFat)
            }
        }
    }

    private func macroMini(_ label: String, _ grams: Int, _ color: Color) -> some View {
        HStack(spacing: 8) {
            ProgressRing(value: grams > 0 ? 1 : 0, lineWidth: 5, tint: AnyShapeStyle(color))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(grams) g").font(.subheadline.bold().monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
