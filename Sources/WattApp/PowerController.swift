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

    /// Pressione termica dalla stessa chiave notify(3) che legge
    /// `powermetrics`. Costa una lettura di memoria condivisa, quindi la
    /// misura vera e' disponibile a ogni giro invece che solo a menu aperto.
    private let pressureMonitor = ThermalPressureMonitor()

    /// Batteria: registro IO, nessun privilegio, cambia lentamente.
    private let battery = BatteryHistory()

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
    private(set) var batterySnapshot: BatterySnapshot?

    /// Storico del degrado, letto dal disco all'avvio.
    var batteryTrend: [BatteryHistory.Entry] { battery.entries }
    var batteryDegradation: (points: Double, days: Double, cycles: Int)? {
        battery.degradation
    }
    var batteryMonthsToEighty: Double? { battery.monthsToEightyPercent }
    var batteryTrendIsMeaningful: Bool { battery.isTrendMeaningful }

    var onChange: (() -> Void)?

    init(helper: HelperConnection) {
        self.helper = helper
        self.profile = Preferences.selectedProfile
        self.keepAwake.keepDisplayOn = Preferences.keepDisplayOn
        self.keepAwake.onChange = { [weak self] in self?.notify() }
        self.alert.requestAuthorizationIfNeeded()

        // Il kernel pubblica il cambio di livello nell'istante in cui
        // avviene: a menu chiuso il timer puo' scattare ogni dieci secondi,
        // e dieci secondi di icona sbagliata su un evento che ne dura
        // sessanta sono un sesto della verita' persa per niente.
        self.pressureMonitor.observe { [weak self] _ in
            Task { @MainActor in self?.refreshPressureOnly() }
        }

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

        var sample = lastSample ?? PowerSample()
        if let reading = ioReport?.sample() {
            sample.pCoreMHz = reading.pCoreMHz
            sample.eCoreMHz = reading.eCoreMHz
            sample.pCoreCeilingMHz = reading.pCoreCeilingMHz
            sample.eCoreCeilingMHz = reading.eCoreCeilingMHz
            // Senza il riposo, "1,1 GHz su 3,5" si legge come una
            // limitazione anche quando e' solo una macchina ferma.
            sample.pCoreIdleRatio = reading.pCoreIdleFraction
        }
        resolvePressure(in: &sample)
        sample.sampledAt = Date()
        lastSample = sample

        if let summary = temperatures, let maximum = summary.socCelsius {
            // Entrambe le curve vengono dal *solo* die, e su tutti e sedici
            // i sensori anche quando il giro ne ha riletti quattro.
            //
            // Prima la media era su `all`, cioe' su un insieme che cambia
            // dimensione a ogni giro: quattro sensori caldi nei giri veloci,
            // sedici piu' batteria e SSD in quelli completi. Il risultato era
            // un dente di sega periodico nel grafico, che non corrispondeva
            // a nulla di fisico e si leggeva come throttling a intermittenza.
            history.append(maximum: maximum,
                           average: summary.socAverageCelsius ?? maximum)
            // L'allarme guarda la pressione **misurata**, non piu' la stima
            // di ProcessInfo: era l'unico punto rimasto in cui l'app
            // decideva su un dato che sapeva essere sbagliato di un livello.
            alert.evaluate(socCelsius: maximum,
                           throttling: sample.thermalPressure.isThrottling)
        }

        refreshBattery()
        notify()
    }

    /// Aggiorna solo la pressione termica, senza rileggere nient'altro.
    ///
    /// La chiama l'osservatore del kernel quando il livello cambia: rifare
    /// l'intero giro di campionamento a ogni transizione costerebbe piu'
    /// dell'informazione che porta.
    private func refreshPressureOnly() {
        var sample = lastSample ?? PowerSample()
        resolvePressure(in: &sample)
        lastSample = sample
        notify()
    }

    /// Decide da quale fonte prendere la pressione termica.
    ///
    /// L'ordine e' per qualita' del dato, non per comodita':
    ///
    /// 1. il **kernel**, su `com.apple.system.thermalpressurelevel`. E' la
    ///    stessa sorgente da cui legge `powermetrics` — nel binario di
    ///    powermetrics c'e' la stringa "thermal pressure notifications" — ma
    ///    e' sempre attuale e non costa niente. La verifica appaiata sta in
    ///    `Watt --verify-pressure`;
    /// 2. un campione **recente** di powermetrics, se il kernel non e'
    ///    leggibile;
    /// 3. `ProcessInfo`, che sbaglia di un livello intero e va usato solo
    ///    quando non c'e' altro.
    ///
    /// Prima qui c'era il passo 3 da solo, e sovrascriveva il passo 2 anche
    /// quando questo era appena arrivato: la misura veniva pagata con mezzo
    /// secondo di powermetrics e poi buttata via.
    private func resolvePressure(in sample: inout PowerSample) {
        if let level = pressureMonitor.level {
            sample.thermalPressureRaw = level.rawValue
            sample.thermalPressureSource = .kernel
            return
        }
        let fresh = sample.thermalPressureSource == .powermetrics
            && Date().timeIntervalSince(sample.sampledAt) < 30
        guard !fresh else { return }
        sample.thermalPressureRaw = ThermalPressure(
            processInfoState: ProcessInfo.processInfo.thermalState).rawValue
        sample.thermalPressureSource = .processInfo
    }

    /// Rilegge la batteria e, se il caso, ne annota un punto nello storico.
    ///
    /// Costa una lettura del registro IO — meno di un millesimo di quanto
    /// costano i sensori termici — ma le grandezze che conta davvero (cicli,
    /// capacita' a piena carica) cambiano nell'arco di settimane: e' lo
    /// storico ad avere una cadenza, non la lettura.
    private func refreshBattery() {
        guard let snapshot = BatteryReader.read() else { return }
        batterySnapshot = snapshot
        battery.record(snapshot, temperature: temperatures?.batteryCelsius)
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
            // La pressione termica arriva nello stesso campione dei watt e
            // costa quanto loro: scartarla e tenere solo le potenze
            // significava rifare la misura precisa e non usarla mai.
            // Non si controlla il flag ma la presenza del valore:
            // l'helper legge la pressione solo da powermetrics, quindi un
            // campo pieno *e'* una misura. Cosi' la correzione vale anche
            // con l'helper gia' installato, che il flag non lo manda.
            //
            // Il kernel resta comunque la fonte migliore: e' la stessa, ma
            // attuale invece che vecchia di mezzo secondo. Questo ramo serve
            // ai Mac o alle versioni di macOS dove la chiave notify non
            // risponde.
            if self.pressureMonitor.level == nil,
               let pressure = sample.thermalPressureRaw {
                merged.thermalPressureRaw = pressure
                merged.thermalPressureSource = .powermetrics
            }
            merged.sampledAt = Date()
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
