import LocalAuthentication
import SwiftUI
import UIKit

/// Optionele vergrendeling van de app zelf.
///
/// Wat dit wél is: een slot op het scherm. Het houdt iemand die je telefoon even
/// vasthoudt buiten je gewicht, je foto's en je check-ins. Wat het níét is:
/// versleuteling — de database staat gewoon in de app-container, precies zoals daarvoor.
///
/// De instelling blijft bewust op dit toestel en gaat niet mee met de sync. Een slot is
/// iets van de telefoon in je hand, niet van je account: meesturen zou je tweede toestel
/// op slot zetten zonder dat je daar ooit bent geweest.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    nonisolated static let key = "appLockOn"

    /// Aan of uit. Ook buiten een view leesbaar, want de widget-snapshot en de Live
    /// Activity moeten het ook weten.
    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Lang genoeg dat de camera, een deelblad of een systeemdialoog je er niet uitgooit
    /// — die zetten de app even weg zonder dat je 'm uit handen geeft. Kort genoeg dat
    /// "telefoon neergelegd" wel op slot gaat.
    nonisolated static let grace: TimeInterval = 30

    /// Het enige wat hier te rekenen valt, dus ook het enige wat mis kan gaan: apart,
    /// zodat een test er los bij kan.
    nonisolated static func shouldLock(leftAt: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(leftAt) >= grace
    }

    /// Wat dit toestel aanbiedt, voor de knop en de instelling. Eén keer bepaald: het
    /// verandert niet terwijl de app draait.
    nonisolated static let biometryName: String = {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) // vult biometryType
        return switch ctx.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        default: "je toegangscode"
        }
    }()

    /// Kan het toestel überhaupt iets vragen? Zonder toegangscode is er niets om mee te
    /// ontgrendelen, en dan is dit een deur zonder sleutel.
    nonisolated static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Op slot tot je jezelf hebt aangetoond. Start als de instelling aanstaat: bij een
    /// koude start hoort er niets zichtbaar te zijn vóór dat gebeurd is.
    private(set) var locked = AppLock.isOn
    private var leftAt: Date?
    private var authenticating = false
    @ObservationIgnored private var window: UIWindow?

    /// Bij het opstarten van de app.
    func start() {
        guard Self.isOn else { return }
        cover(locked)
        if locked { Task { await authenticate() } }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard Self.isOn else { cover(false); return }
        switch phase {
        case .active:
            // Alleen ná de gratieperiode gaat het slot erop — en alleen dán vragen we er
            // vanzelf om. Wie annuleert krijgt de knop, geen tweede dialoog in de rug.
            let justLocked = !locked && leftAt.map { Self.shouldLock(leftAt: $0) } == true
            if justLocked { locked = true }
            leftAt = nil
            cover(locked)
            if justLocked { Task { await authenticate() } }
        case .inactive:
            // De app-switcher bewaart een plaat van dit moment; daar hoort niets op te staan.
            cover(true)
        case .background:
            leftAt = leftAt ?? .now
            cover(true)
        @unknown default:
            cover(true)
        }
    }

    func authenticate() async {
        guard locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Annuleer"
        // Bewust niet `...WithBiometrics`: valt Face ID uit (masker, donker, te vaak
        // mis), dan moet de toegangscode je er alsnog in laten. Anders sluit je jezelf
        // buiten je eigen trainingen.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // Toegangscode van het toestel gehaald ná het aanzetten: er valt niets meer
            // te controleren, en een slot dat niemand kan openen is erger dan geen slot.
            unlock()
            return
        }
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: "Ontgrendel Built om je gegevens te zien")) == true
        else { return }
        unlock()
    }

    private func unlock() {
        locked = false
        cover(false)
    }

    /// Het slot woont in een eigen venster boven de app. Een overlay in de view-hiërarchie
    /// dekt alleen af wat eronder ligt: staat er een sheet open als je de app wegzet, dan
    /// kijk je daar bij terugkomst overheen — en kun je 'm ook nog bedienen. Een venster
    /// op alert-niveau ligt over álles.
    private func cover(_ visible: Bool) {
        if visible, window == nil,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let host = UIHostingController(rootView: LockScreen())
            host.view.backgroundColor = UIColor.systemGroupedBackground // geen doorschijnende flits
            let lockWindow = UIWindow(windowScene: scene)
            lockWindow.windowLevel = .alert + 1
            lockWindow.rootViewController = host
            window = lockWindow
        }
        window?.isHidden = !visible
    }
}

/// Wat je ziet als de app op slot staat. Ondoorzichtig en niet vervaagd: door een blur
/// herken je je eigen grafieken en foto's nog prima.
struct LockScreen: View {
    private let lock = AppLock.shared

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                    .frame(width: 64, height: 64)
                    .background(.builtTint(.green), in: Circle())
                    .accessibilityHidden(true)
                Text("Built is vergrendeld")
                    .font(.headline)
                // Tijdens de gratieperiode dekt ditzelfde scherm alleen maar af. Dan is er
                // niets te ontgrendelen, dus staat er ook geen knop die niets doet.
                if lock.locked {
                    Text("Ontgrendel met \(AppLock.biometryName) om je gegevens te zien.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Ontgrendelen") {
                        Task { await lock.authenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.green)
                    .padding(.top, 4)
                }
            }
            .padding(32)
        }
    }
}
