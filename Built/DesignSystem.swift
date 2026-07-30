import SwiftUI

// De bron voor kleur, maat en vorm. Schermen horen hier uit te putten en niets
// zelf na te bouwen — zie .design-system.md.

// MARK: - Maten

enum BuiltRadius {
    static let micro: CGFloat = 4    // heatmap-blokje
    static let small: CGFloat = 8    // icoontegel, invoerveld
    static let medium: CGFloat = 14  // tegel, klein vlak
    static let card: CGFloat = 20    // kaart
    static let floating: CGFloat = 26 // zwevende pill, tab bar
}

/// Eén dekking voor elk getint vlak achter een icoon of badge. Het verschil tussen
/// 0,15 en 0,18 ziet niemand, maar naast elkaar valt het wél op.
extension ShapeStyle where Self == Color {
    static func builtTint(_ color: Color) -> Color { color.opacity(0.15) }
}

// MARK: - Kleuren

/// Data-kleuren. Groen blijft het merk-accent; deze coderen alléén data.
/// Eiwit = groen (de held), koolhydraten = oranje, vet = indigo.
extension Color {
    static let macroProtein = Color.green
    static let macroCarbs = Color.orange
    static let macroFat = Color.indigo

    // Habit-identiteit: één vaste kleur per rij, zodat je 'm op kleur herkent zonder
    // te lezen. Hoort hier en niet in een view — de widget gebruikt dezelfde set.
    static let habitTraining = Color.orange
    static let habitCreatine = Color.teal
    static let habitWeight = Color.purple
    static let habitSleep = Color.indigo
    static let habitSteps = Color.cyan
    static let habitCustom = Color.mint
    static let habitJournal = Color.gray

    /// Groen-intensiteit voor de body-map: meer volume = voller groen op een grijze basis.
    static func muscleTint(_ value: Double) -> Color {
        let v = min(max(value, 0), 1)
        return v <= 0.001 ? Color(.tertiarySystemFill) : Color.green.opacity(0.22 + 0.6 * v)
    }

    /// Kleur per spiergroep — geeft een routine een gezicht, zodat je Push van Legs
    /// herkent zonder te lezen. Duw-werk warm, trek-werk koel, benen paars.
    static func muscle(_ name: String) -> Color {
        switch name {
        case "Borst", "Triceps", "Schouders": .orange
        case "Rug", "Biceps", "Onderrug": .blue
        case "Benen", "Hamstrings", "Bilspieren", "Kuiten": .purple
        case "Core": .teal
        case "Cardio": .pink
        default: .green
        }
    }
}

// MARK: - Scherm-chrome

/// Groot ankerpunt bovenaan een scherm: één regel context, één regel gewicht.
/// Zonder dit begint elk scherm op `.headline` en heeft niets voorrang.
struct BuiltScreenTitle<Trailing: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            trailing()
        }
        .padding(.top, 8)
    }
}

extension BuiltScreenTitle where Trailing == EmptyView {
    init(_ eyebrow: String, _ title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// Sectiekop buiten een List. Zelfde micro-label als de check-in-drawer al gebruikt,
/// met ruimte voor een actie rechts.
struct BuiltSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

extension BuiltSectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Toelichting onder een kaart — vervangt de footer van een List-sectie.
struct BuiltFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Vastgezette hoofdactie

/// De knop onderaan een scherm ("Start deze training", "Klaar", "Log 139 kcal").
/// Eén set marges, zodat hij overal even ver van de rand — en van de zwevende tab bar — staat.
/// Stond eerder op drie plekken met drie verschillende waarden.
struct BuiltBottomAction: ViewModifier {
    func body(content: Content) -> some View {
        content
            .controlSize(.large) // hogere knop; .borderedProminent is standaard krap
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
    }
}

extension View {
    func builtBottomAction() -> some View { modifier(BuiltBottomAction()) }
}

// MARK: - Kaart

/// Eén kaart-stijl voor de hele app.
struct BuiltCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: BuiltRadius.card, style: .continuous))
    }
}

extension View {
    func builtCard(padding: CGFloat = 16) -> some View { modifier(BuiltCard(padding: padding)) }
}

// MARK: - Stat-tegel

/// Getal boven, label onder — de statrij van een training, sessie en Inzicht.
/// Stond eerder drie keer los in twee bestanden, met verschillende lettergroottes.
struct StatTile: View {
    let value: String
    let label: String
    /// Prominente variant voor de statrij bovenaan een scherm.
    var large = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font((large ? Font.title : Font.title2).bold().monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, large ? 4 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Icoontegel

/// Gekleurd vierkantje met een SF Symbol — de linkerkant van elke habit-rij.
/// Schaalt mee met Dynamic Type, anders zit het icoon klem bij grote letters.
struct BuiltIconTile: View {
    let systemName: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: BuiltRadius.small, style: .continuous)
            .fill(.builtTint(color))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.subheadline)
                    .foregroundStyle(color)
            }
    }
}

// MARK: - Streak-badge

/// 🔥 n. Pas vanaf 2 dagen — "🔥 1" is geen reeks en devalueert het vlammetje.
struct StreakBadge: View {
    let days: Int

    var body: some View {
        if days >= 2 {
            HStack(spacing: 2) {
                Text("🔥").font(.caption2)
                Text("\(days)").font(.caption2.bold().monospacedDigit())
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.builtTint(.orange), in: Capsule())
            .foregroundStyle(.orange)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: days)
            .accessibilityLabel("\(days) dagen op rij")
        }
    }
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
                // max(0.0001, …): op 0% tekent SwiftUI anders een flikkerend puntje
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
                    Text("van \(proteinTarget) g").font(.caption2).foregroundStyle(.secondary)
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

    // Koolhydraten/vet hebben geen doel → een gekleurde stip i.p.v. een (altijd volle,
    // misleidende) ring. Geen valse "doel bereikt"-suggestie.
    private func macroMini(_ label: String, _ grams: Int, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(grams) g").font(.subheadline.bold().monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(grams) gram")
    }
}

// MARK: - Previews
//
// Alle componenten naast elkaar. Zonder deze plek ontstaat drift: dan bouwt een scherm
// z'n eigen kaart of ring omdat niemand ziet dat die al bestaat.

#Preview("Componenten") {
    ScrollView {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack {
                    StatTile(value: "52", label: "minuten")
                    StatTile(value: "4.320", label: "kg volume")
                    StatTile(value: "18", label: "sets")
                }
                Divider()
                HStack {
                    StatTile(value: "12", label: "van 30 dagen", large: true)
                    StatTile(value: "🔥 5", label: "huidige reeks", large: true)
                }
            }
            .builtCard()

            VStack(spacing: 0) {
                habitRow("dumbbell.fill", .habitTraining, "Training", 3, true)
                Divider()
                habitRow("pills.fill", .habitCreatine, "Creatine", 0, false)
                Divider()
                habitRow("figure.walk", .habitSteps, "8.412 stappen", 5, true)
            }
            .builtCard()

            HStack(spacing: 20) {
                ProgressRing(value: 0.36, lineWidth: 12,
                             tint: AnyShapeStyle(AngularGradient(colors: [.green, .mint, .green], center: .center))) {
                    Text("36").font(.title.bold().monospacedDigit())
                }
                .frame(width: 96, height: 96)
                ProgressRing(value: 0.7) {
                    Text("70").font(.headline.monospacedDigit())
                }
                .frame(width: 64, height: 64)
                ProgressRing(value: 0) // rand-geval: mag geen puntje tonen
                    .frame(width: 44, height: 44)
            }
            .builtCard()

            MacroRings(protein: 82, proteinTarget: 120, carbs: 210, fat: 64)
                .builtCard()
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}

@ViewBuilder
private func habitRow(_ icon: String, _ color: Color, _ title: String, _ streak: Int, _ done: Bool) -> some View {
    HStack(spacing: 12) {
        BuiltIconTile(systemName: icon, color: color)
        Text(title)
            .foregroundStyle(done ? .secondary : .primary)
            .strikethrough(done, color: .secondary)
        StreakBadge(days: streak)
        Spacer()
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(done ? .green : .secondary)
    }
    .padding(.vertical, 11)
}
