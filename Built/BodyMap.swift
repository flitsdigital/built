import SwiftUI

/// Gestileerde voor/achter-figuur waarin spieren oplichten op volume.
/// Getrackte spieren tinten groen (meer volume = voller), de rest blijft grijs.
struct BodyMapView: View {
    /// Spiergroep → intensiteit 0…1.
    var values: [String: Double]
    var onTap: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 20) {
            figure(BodyMapView.front, caption: "Voor")
            figure(BodyMapView.back, caption: "Achter")
        }
        .frame(maxWidth: .infinity)
    }

    private func figure(_ zones: [Zone], caption: String) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    ForEach(zones) { zone in
                        zoneView(zone, size: geo.size)
                    }
                }
                .animation(.smooth(duration: 0.4), value: values)
            }
            .frame(width: 120, height: 250)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func color(for zone: Zone) -> Color {
        guard let m = zone.muscle else { return Color(.tertiarySystemFill) }
        return Color.muscleTint(values[m] ?? 0)
    }

    @ViewBuilder private func zoneView(_ zone: Zone, size: CGSize) -> some View {
        let c = color(for: zone)
        Group {
            switch zone.shape {
            case .ellipse: Ellipse().fill(c)
            case .capsule: Capsule().fill(c)
            case .rounded: RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c)
            }
        }
        .frame(width: zone.rect.width * size.width, height: zone.rect.height * size.height)
        .position(x: zone.rect.midX * size.width, y: zone.rect.midY * size.height)
        .onTapGesture { if let m = zone.muscle { onTap(m) } }
    }

    // MARK: - Zones

    struct Zone: Identifiable {
        let id = UUID()
        let muscle: String?          // nil = neutraal (hoofd, onderarm…)
        let rect: CGRect             // genormaliseerd 0…1 in de figuur
        let shape: ZoneShape
    }
    enum ZoneShape { case ellipse, capsule, rounded }

    private static func z(_ m: String?, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ s: ZoneShape = .ellipse) -> Zone {
        Zone(muscle: m, rect: CGRect(x: x, y: y, width: w, height: h), shape: s)
    }

    static let front: [Zone] = [
        z(nil, 0.41, 0.02, 0.18, 0.12),                       // hoofd
        z(nil, 0.45, 0.12, 0.10, 0.05, .capsule),             // nek
        z("Schouders", 0.22, 0.16, 0.17, 0.11),
        z("Schouders", 0.61, 0.16, 0.17, 0.11),
        z("Borst", 0.33, 0.18, 0.17, 0.12),
        z("Borst", 0.50, 0.18, 0.17, 0.12),
        z("Biceps", 0.16, 0.26, 0.12, 0.18, .capsule),
        z("Biceps", 0.72, 0.26, 0.12, 0.18, .capsule),
        z(nil, 0.13, 0.44, 0.10, 0.17, .capsule),             // onderarm
        z(nil, 0.77, 0.44, 0.10, 0.17, .capsule),
        z("Core", 0.37, 0.30, 0.26, 0.20, .rounded),
        z("Benen", 0.33, 0.52, 0.15, 0.24, .capsule),
        z("Benen", 0.52, 0.52, 0.15, 0.24, .capsule),
        z("Kuiten", 0.35, 0.77, 0.12, 0.20, .capsule),
        z("Kuiten", 0.53, 0.77, 0.12, 0.20, .capsule),
    ]

    static let back: [Zone] = [
        z(nil, 0.41, 0.02, 0.18, 0.12),
        z(nil, 0.45, 0.12, 0.10, 0.05, .capsule),
        z("Schouders", 0.22, 0.16, 0.17, 0.11),
        z("Schouders", 0.61, 0.16, 0.17, 0.11),
        z("Rug", 0.33, 0.18, 0.34, 0.17, .rounded),
        z("Onderrug", 0.39, 0.35, 0.22, 0.10, .rounded),
        z("Triceps", 0.16, 0.26, 0.12, 0.18, .capsule),
        z("Triceps", 0.72, 0.26, 0.12, 0.18, .capsule),
        z(nil, 0.13, 0.44, 0.10, 0.17, .capsule),
        z(nil, 0.77, 0.44, 0.10, 0.17, .capsule),
        z("Bilspieren", 0.35, 0.46, 0.14, 0.13),
        z("Bilspieren", 0.51, 0.46, 0.14, 0.13),
        z("Hamstrings", 0.33, 0.59, 0.15, 0.19, .capsule),
        z("Hamstrings", 0.52, 0.59, 0.15, 0.19, .capsule),
        z("Kuiten", 0.35, 0.79, 0.12, 0.18, .capsule),
        z("Kuiten", 0.53, 0.79, 0.12, 0.18, .capsule),
    ]
}
