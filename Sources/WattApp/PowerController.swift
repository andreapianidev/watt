import Foundation
import WattKit

/// Coordina le due meta' di un profilo: quella privilegiata, che passa
/// dall'helper, e quella non privilegiata, che l'app applica da se'.
@MainActor
final class PowerController {

    private let helper: HelperConnection
    private let sleepAssertion = SleepAssertion()

    private(set) var profile: PowerProfile
    private(set) var lastSample: PowerSample?
    private(set) var lastState: SystemState?
    private(set) var lastError: String?

    var onChange: (() -> Void)?

    init(helper: HelperConnection) {
        self.helper = helper
        self.profile = Preferences.selectedProfile
    }

    // MARK: - Profili

    func apply(_ profile: PowerProfile,
               completion: (@MainActor @Sendable () -> Void)? = nil) {
        self.profile = profile
        Preferences.selectedProfile = profile

        let plan = profile.plan
        // La parte senza privilegi si applica subito: non dipende
        // dall'helper e resta valida anche se l'utente non l'ha approvato.
        AppNapControl.setDisabled(plan.disableAppNap)
        if plan.preventIdleSleep {
            sleepAssertion.acquire(reason: "Watt: profilo \(profile.title)")
        } else {
            sleepAssertion.release()
        }
        notify()

        helper.applyProfile(profile) { [weak self] failure in
            guard let self else { return }
            self.lastError = failure
            self.refreshState()
            completion?()
        }
    }

    /// Riapplica il profilo salvato all'avvio. Le impostazioni di pmset
    /// sopravvivono ai riavvii, ma l'assertion di sospensione e App Nap no:
    /// senza questo, dopo un riavvio l'app direbbe "Massimo" mentre meta'
    /// del profilo non sarebbe in vigore.
    func reapplyAtLaunch() {
        apply(profile)
    }

    // MARK: - Letture

    func refreshState() {
        helper.readSystemState { [weak self] state in
            guard let self else { return }
            if var state {
                // L'helper non puo' leggere App Nap: gira come root e la
                // chiave vive nel dominio dell'utente.
                state.appNapDisabled = AppNapControl.isDisabled
                self.lastState = state
            }
            self.notify()
        }
    }

    func refreshMetrics() {
        helper.sampleMetrics { [weak self] sample in
            guard let self else { return }
            if let sample { self.lastSample = sample }
            self.notify()
        }
    }

    var sleepPrevented: Bool { sleepAssertion.isActive }

    private func notify() { onChange?() }
}
