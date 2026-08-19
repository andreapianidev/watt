import Foundation
import WattKit

/// Coordina le due meta' di un profilo: quella privilegiata, che passa
/// dall'helper, e quella non privilegiata, che l'app applica da se'.
@MainActor
final class PowerController {

    private let helper: HelperConnection
    private let sleepAssertion = SleepAssertion()

    /// Frequenze lette direttamente da IOReport: nessun processo da lanciare,
    /// nessun privilegio richiesto, risposta immediata. `nil` solo se
    /// l'API non e' disponibile su questa versione di macOS.
    private let ioReport = IOReportSampler()

    /// Sensori termici HID. Come IOReport non richiedono privilegi, quindi
    /// restano nell'app e funzionano anche senza helper installato.
    private let sensors = ThermalSensors()

    /// Sveglia controllata dall'utente, indipendente dal profilo: un Mac
    /// tenuto sveglio durante una build non ha niente a che vedere con la
    /// scelta del profilo energetico, e mescolarle renderebbe entrambe
    /// imprevedibili.
    let keepAwake = KeepAwake()

    private(set) var profile: PowerProfile
    private(set) var lastSample: PowerSample?
    private(set) var memory: MemoryReader.Snapshot?
    private(set) var temperatures: ThermalSensors.Summary?
    private(set) var lastState: SystemState?
    private(set) var lastError: String?

    var onChange: (() -> Void)?

    init(helper: HelperConnection) {
        self.helper = helper
        self.profile = Preferences.selectedProfile
        self.keepAwake.keepDisplayOn = Preferences.keepDisplayOn
        self.keepAwake.onChange = { [weak self] in self?.notify() }
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

    /// Aggiornamento leggero: frequenze, stato termico e memoria.
    ///
    /// Nessuna di queste letture lancia processi o richiede privilegi, per
    /// cui puo' girare di continuo senza che l'app diventi essa stessa una
    /// voce di consumo. I watt, che invece costano un `powermetrics`, si
    /// chiedono solo quando il menu e' aperto.
    func refreshMetrics() {
        memory = MemoryReader.read()
        temperatures = sensors?.read()

        var sample = lastSample ?? PowerSample()
        if let reading = ioReport?.sample() {
            sample.pCoreMHz = reading.pCoreMHz
            sample.eCoreMHz = reading.eCoreMHz
            sample.pCoreCeilingMHz = reading.pCoreCeilingMHz
            sample.eCoreCeilingMHz = reading.eCoreCeilingMHz
        }
        sample.thermalPressureRaw = ThermalPressure(
            processInfoState: ProcessInfo.processInfo.thermalState).rawValue
        sample.sampledAt = Date()
        lastSample = sample
        notify()
    }

    /// Chiede all'helper un campione di `powermetrics` per i soli watt.
    /// Da invocare con parsimonia: ogni campione fa girare powermetrics per
    /// mezzo secondo, e quel mezzo secondo consuma.
    func refreshPower() {
        helper.sampleMetrics { [weak self] sample in
            guard let self, let sample else { return }
            var merged = self.lastSample ?? PowerSample()
            merged.packageMilliwatts = sample.packageMilliwatts
            merged.cpuMilliwatts = sample.cpuMilliwatts
            merged.gpuMilliwatts = sample.gpuMilliwatts
            self.lastSample = merged
            self.notify()
        }
    }

    func purgeMemory(completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
        helper.purgeMemory { [weak self] failure in
            guard let self else { return }
            self.lastError = failure
            self.memory = MemoryReader.read()
            self.notify()
            completion?(failure)
        }
    }

    func setKeepAwake(_ mode: KeepAwake.Mode) {
        keepAwake.set(mode)
        notify()
    }

    func setKeepDisplayOn(_ on: Bool) {
        keepAwake.keepDisplayOn = on
        Preferences.keepDisplayOn = on
        notify()
    }

    var sleepPrevented: Bool { sleepAssertion.isActive }

    private func notify() { onChange?() }
}
