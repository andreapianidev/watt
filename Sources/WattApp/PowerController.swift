import AppKit
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
    private let alert = TemperatureAlert()

    private(set) var history = TemperatureHistory()
    private(set) var throttleReport: ThrottleReport?
    private(set) var suspendedServices: [String] = []
    private(set) var findings: [Diagnosis.Finding] = []
    private(set) var processes: [ProcessSnapshot.Entry] = []

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
        self.alert.requestAuthorizationIfNeeded()

        // Un cambio di profilo fatto da riga di comando deve comparire subito
        // nel menu, non alla prossima interazione.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Preferences.profileChangedNotification),
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.object as? String,
                  let profile = PowerProfile(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, profile != self.profile else { return }
                self.profile = profile
                self.syncLocalSideEffects(for: profile)
                self.notify()
            }
        }
    }

    // MARK: - Profili

    func apply(_ profile: PowerProfile,
               completion: (@MainActor @Sendable () -> Void)? = nil) {
        self.profile = profile
        Preferences.selectedProfile = profile

        let plan = profile.plan
        // La parte senza privilegi si applica subito: non dipende
        // dall'helper e resta valida anche se l'utente non l'ha approvato.
        syncLocalSideEffects(for: profile)
        notify()

        helper.applyProfile(profile) { [weak self] failure in
            guard let self else { return }
            self.lastError = failure

            // Solo Massimo sceglie da sé cosa rallentare. Gli altri profili
            // rimettono a posto: un processo lasciato confinato sugli E-core
            // dopo che sei tornato ad Automatico è una modifica invisibile
            // che l'utente non ha modo di scoprire né di annullare.
            if plan.demoteBackgroundDaemons {
                self.helper.throttleHeavyBackground { report in
                    self.throttleReport = report
                    self.notify()
                }
                self.helper.suspendServices { report in
                    self.suspendedServices = report?.suspended ?? []
                    self.notify()
                }
            } else if self.throttleReport != nil || !self.suspendedServices.isEmpty {
                self.helper.resumeServices { _ in
                    self.suspendedServices = []
                    self.notify()
                }
                self.helper.restoreThrottled { _ in
                    self.throttleReport = nil
                    self.notify()
                }
            }

            self.refreshState()
            completion?()
        }
    }

    /// Effetti del profilo che non richiedono privilegi. Vanno riapplicati
    /// anche quando il profilo cambia per iniziativa di un altro processo.
    private func syncLocalSideEffects(for profile: PowerProfile) {
        let plan = profile.plan
        AppNapControl.setDisabled(plan.disableAppNap)
        if plan.preventIdleSleep {
            sleepAssertion.acquire(reason: "Watt: profilo \(profile.title)")
        } else {
            sleepAssertion.release()
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

    /// Rete di sicurezza per il caso in cui la notifica si perda: rilegge la
    /// preferenza dal disco e si allinea senza riapplicare nulla al sistema,
    /// che è già stato configurato da chi ha fatto il cambio.
    func adoptExternalProfileChange() {
        let stored = Preferences.reloadedProfile()
        guard stored != profile else { return }
        profile = stored
        syncLocalSideEffects(for: stored)
        notify()
    }

    /// Rianalizza cosa sta limitando la macchina.
    ///
    /// Richiede la tabella dei processi all'helper, quindi non gira nel ciclo
    /// di aggiornamento continuo: si aggiorna quando apri il menu, che e'
    /// quando la risposta serve.
    func refreshDiagnosis() {
        helper.processSnapshot { [weak self] entries in
            guard let self else { return }
            self.processes = entries
            let foreground = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier))
            self.findings = Diagnosis.analyze(
                sample: self.lastSample, memory: self.memory,
                state: self.lastState, processes: entries,
                foregroundPIDs: foreground)
            self.notify()
        }
    }

    /// Esegue il rimedio proposto da un verdetto.
    func apply(_ remedy: Diagnosis.Remedy) {
        switch remedy {
        case .switchProfile(let profile): apply(profile)
        case .freezeServices:             toggleServiceSuspension()
        case .throttleBackground:         throttleNow()
        case .none:                       break
        }
    }

    /// Lettura completa di tutti i sensori, per l'elenco dettagliato.
    func refreshAllSensors() {
        guard let full = sensors?.read() else { return }
        temperatures = full
        notify()
    }

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
        // Lettura adattiva: i sensori piu' caldi a ogni giro, il die intero
        // ogni tanto, batteria e SSD di rado. Costa un terzo della lettura
        // essenziale e un decimo di quella completa, che si fa solo quando
        // l'elenco integrale e' a schermo.
        temperatures = sensors?.readAdaptive()

        if let summary = temperatures, !summary.all.isEmpty {
            // La media è su tutti i sensori, la massima è il punto più caldo:
            // insieme dicono se scalda tutto il SoC o un solo cluster.
            let values = summary.all.map(\.celsius)
            history.append(maximum: values.max() ?? 0,
                           average: values.reduce(0, +) / Double(values.count))
            alert.evaluate(
                socCelsius: summary.socCelsius,
                throttling: ThermalPressure(
                    processInfoState: ProcessInfo.processInfo.thermalState)
                    .isThrottling)
        }

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

    /// Rallentamento su richiesta, indipendente dal profilo.
    func throttleNow(completion: (@MainActor @Sendable (ThrottleReport?) -> Void)? = nil) {
        helper.throttleHeavyBackground { [weak self] report in
            guard let self else { return }
            self.throttleReport = report
            self.notify()
            completion?(report)
        }
    }

    func restoreThrottled() {
        helper.restoreThrottled { [weak self] _ in
            guard let self else { return }
            self.throttleReport = nil
            self.notify()
        }
    }

    func toggleServiceSuspension() {
        if suspendedServices.isEmpty {
            helper.suspendServices { [weak self] report in
                self?.suspendedServices = report?.suspended ?? []
                self?.notify()
            }
        } else {
            helper.resumeServices { [weak self] _ in
                self?.suspendedServices = []
                self?.notify()
            }
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
