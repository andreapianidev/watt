import AppKit
import WattKit

/// L'elemento in menu bar e il suo menu.
///
/// Due funzioni in un solo elemento: il profilo energetico e la sveglia. Si
/// somigliano abbastanza da stare insieme (entrambe riguardano cosa il Mac
/// puo' fare mentre lavori) e restano separate abbastanza da non
/// interferire: la sveglia non cambia il profilo e il profilo non cambia la
/// sveglia.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let controller: PowerController
    private let helper: HelperConnection
    private lazy var poller = MetricsPoller { [weak self] in
        self?.controller.refreshMetrics()
    }

    private let menu = NSMenu()
    private var profileItems: [PowerProfile: NSMenuItem] = [:]
    private var stateItems: [NSMenuItem] = []
    private var keepAwakeRoot = NSMenuItem()
    private var keepAwakeItems: [NSMenuItem] = []
    private var displayToggle = NSMenuItem()
    private var launchItem = NSMenuItem()
    private var sensorsRoot = NSMenuItem()
    private var isMenuOpen = false
    private var barDisplayItems: [NSMenuItem] = []
    private var thresholdItems: [NSMenuItem] = []
    private var cadenceItems: [NSMenuItem] = []
    private var suspendItem = NSMenuItem()
    private var alertsToggle = NSMenuItem()
    private let chartView = TemperatureChartView()
    private let chartItem = NSMenuItem()
    private var throttleRoot = NSMenuItem()

    /// Le voci della sveglia, nell'ordine in cui compaiono.
    private static let awakeModes: [KeepAwake.Mode] = [
        .off, .indefinite,
        .duration(15 * 60), .duration(30 * 60),
        .duration(60 * 60), .duration(2 * 60 * 60), .duration(5 * 60 * 60),
        .whileBuilding,
    ]

    init(controller: PowerController, helper: HelperConnection) {
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        self.controller = controller
        self.helper = helper
        super.init()

        buildMenu()
        statusItem.menu = menu
        menu.delegate = self

        controller.onChange = { [weak self] in self?.render() }
        poller.start()
        render()
    }

    // MARK: - Costruzione

    private func buildMenu() {
        // AppKit disabilita da se' le voci senza azione, e una voce
        // disabilitata viene disegnata semitrasparente: era il motivo per cui
        // temperature e frequenze risultavano illeggibili. Spegnendo
        // l'abilitazione automatica le righe informative restano a piena
        // opacita' pur non essendo cliccabili.
        menu.autoenablesItems = false

        for profile in PowerProfile.allCases {
            let item = NSMenuItem(title: profile.title,
                                  action: #selector(selectProfile(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = profile.rawValue
            item.image = NSImage(systemSymbolName: profile.symbolName,
                                 accessibilityDescription: nil)
            item.toolTip = profile.explanation
            menu.addItem(item)
            profileItems[profile] = item
        }

        menu.addItem(.separator())

        // Righe informative: sola lettura, riflettono lo stato reale letto
        // dal sistema e non il profilo selezionato.
        for _ in 0..<6 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            menu.addItem(item)
            stateItems.append(item)
        }

        menu.addItem(.separator())
        chartView.frame = NSRect(x: 0, y: 0, width: 280, height: 108)
        chartItem.view = chartView
        menu.addItem(chartItem)

        let alertsRoot = NSMenuItem(title: "Avvisi temperatura", action: nil,
                                    keyEquivalent: "")
        let alertsMenu = NSMenu()
        alertsMenu.autoenablesItems = false
        alertsToggle = NSMenuItem(title: "Avvisami quando scotta",
                                  action: #selector(toggleAlerts),
                                  keyEquivalent: "")
        alertsToggle.target = self
        alertsMenu.addItem(alertsToggle)
        alertsMenu.addItem(.separator())
        for threshold in TemperatureAlert.thresholds {
            let item = NSMenuItem(title: String(format: "oltre %.0f °C", threshold),
                                  action: #selector(selectThreshold(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = threshold
            alertsMenu.addItem(item)
            thresholdItems.append(item)
        }
        alertsRoot.submenu = alertsMenu
        alertsRoot.image = NSImage(systemSymbolName: "bell",
                                   accessibilityDescription: nil)
        menu.addItem(alertsRoot)

        sensorsRoot = NSMenuItem(title: "Tutti i sensori", action: nil, keyEquivalent: "")
        sensorsRoot.submenu = NSMenu()
        sensorsRoot.image = NSImage(systemSymbolName: "thermometer.variable",
                                    accessibilityDescription: nil)
        menu.addItem(sensorsRoot)

        menu.addItem(.separator())
        buildKeepAwakeSubmenu()

        let cadenceRoot = NSMenuItem(title: "Aggiornamento", action: nil,
                                     keyEquivalent: "")
        let cadenceMenu = NSMenu()
        cadenceMenu.autoenablesItems = false
        for option in Preferences.Cadence.allCases {
            let item = NSMenuItem(title: option.label,
                                  action: #selector(selectCadence(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            cadenceMenu.addItem(item)
            cadenceItems.append(item)
        }
        cadenceRoot.submenu = cadenceMenu
        cadenceRoot.image = NSImage(systemSymbolName: "timer",
                                    accessibilityDescription: nil)
        menu.addItem(cadenceRoot)

        let displayRoot = NSMenuItem(title: "Mostra in barra", action: nil,
                                     keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        for option in Preferences.BarDisplay.allCases {
            let item = NSMenuItem(title: option.label,
                                  action: #selector(selectBarDisplay(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            displayMenu.addItem(item)
            barDisplayItems.append(item)
        }
        displayRoot.submenu = displayMenu
        menu.addItem(displayRoot)

        throttleRoot = NSMenuItem(title: "Processi in background", action: nil,
                                  keyEquivalent: "")
        throttleRoot.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                     accessibilityDescription: nil)
        throttleRoot.submenu = NSMenu()
        menu.addItem(throttleRoot)

        suspendItem = NSMenuItem(title: "Congela i servizi differibili",
                                 action: #selector(toggleSuspension),
                                 keyEquivalent: "")
        suspendItem.target = self
        suspendItem.image = NSImage(systemSymbolName: "pause.circle",
                                    accessibilityDescription: nil)
        suspendItem.toolTip = "Ferma con SIGSTOP indicizzazione Spotlight, "
                            + "analisi foto, backup e aggiornamenti. "
                            + "Riprendono da dove erano rimasti, e si "
                            + "riattivano da soli dopo mezz'ora."
        menu.addItem(suspendItem)

        let purge = NSMenuItem(title: "Libera memoria adesso",
                               action: #selector(purgeMemory),
                               keyEquivalent: "")
        purge.target = self
        purge.image = NSImage(systemSymbolName: "memorychip",
                              accessibilityDescription: nil)
        purge.toolTip = "Esegue purge: libera la memoria inattiva. Sfratta "
                      + "anche la cache dei file, quindi conviene prima di "
                      + "una build, non durante."
        menu.addItem(purge)

        menu.addItem(.separator())

        launchItem = NSMenuItem(title: "Apri all'avvio",
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)

        let uninstall = NSMenuItem(title: "Ripristina impostazioni e rimuovi helper",
                                   action: #selector(uninstallHelper),
                                   keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)

        let quit = NSMenuItem(title: "Esci", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildKeepAwakeSubmenu() {
        let submenu = NSMenu()
        for mode in Self.awakeModes {
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(selectKeepAwake(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = Self.awakeModes.firstIndex(of: mode)
            if mode == .whileBuilding {
                item.toolTip = "Tiene sveglio il Mac finche' e' in esecuzione "
                             + "xcodebuild, swift-frontend, node, cargo, make, "
                             + "docker e simili."
            }
            submenu.addItem(item)
            keepAwakeItems.append(item)
        }

        submenu.addItem(.separator())
        displayToggle = NSMenuItem(title: "Tieni acceso anche lo schermo",
                                   action: #selector(toggleDisplay),
                                   keyEquivalent: "")
        displayToggle.target = self
        submenu.addItem(displayToggle)

        keepAwakeRoot = NSMenuItem(title: "Sveglia", action: nil, keyEquivalent: "")
        keepAwakeRoot.submenu = submenu
        keepAwakeRoot.image = NSImage(systemSymbolName: "cup.and.saucer",
                                      accessibilityDescription: nil)
        menu.addItem(keepAwakeRoot)
    }

    // MARK: - Rendering

    private func render() {
        renderStatusItem()
        renderProfileChecks()
        renderStateRows()
        renderKeepAwake()
        renderSensors()
        renderThrottle()
        let suspended = controller.suspendedServices
        suspendItem.title = suspended.isEmpty
            ? "Congela i servizi differibili"
            : "Riattiva \(suspended.count) servizi congelati"
        suspendItem.state = suspended.isEmpty ? .off : .on
        chartView.history = controller.history
        chartView.warningCelsius = Preferences.alertThreshold
        alertsToggle.state = Preferences.alertsEnabled ? .on : .off
        for item in thresholdItems {
            item.state = (item.representedObject as? Double
                          == Preferences.alertThreshold) ? .on : .off
            item.isEnabled = Preferences.alertsEnabled
        }
        for item in barDisplayItems {
            item.state = (item.representedObject as? String
                          == Preferences.barDisplay.rawValue) ? .on : .off
        }
        for item in cadenceItems {
            item.state = (item.representedObject as? Double
                          == Preferences.cadence.rawValue) ? .on : .off
        }
        launchItem.state = Preferences.launchAtLogin ? .on : .off
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let sample = controller.lastSample
        let pressure = sample?.thermalPressure ?? .unknown

        // Quando il sistema limita le prestazioni l'elemento cambia colore e
        // simbolo. Un'icona che resta identica mentre perdi il 60% del clock
        // e' inutile: il senso di questa app e' che quel momento si veda.
        let throttling = pressure.isThrottling
        let symbol = throttling
            ? "exclamationmark.triangle.fill"
            : controller.profile.symbolName
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: controller.profile.title)
        button.contentTintColor = throttling ? .systemRed : nil
        button.imagePosition = .imageLeading

        // Ogni voce mostra una grandezza sola: due numeri accostati in barra
        // dei menu diventano illeggibili appena si affollano altre icone.
        let temps = controller.temperatures
        func degrees(_ value: Double?) -> String? {
            value.map { String(format: "%.0f°", $0) }
        }

        var parts: [String] = []
        switch Preferences.barDisplay {
        case .frequency:
            parts = [sample?.pCoreGHzText].compactMap { $0 }
        case .socMax:
            parts = [degrees(temps?.socCelsius)].compactMap { $0 }
        case .socAverage:
            parts = [degrees(temps?.socAverageCelsius)].compactMap { $0 }
        case .battery:
            parts = [degrees(temps?.batteryCelsius)].compactMap { $0 }
        case .storage:
            parts = [degrees(temps?.storageCelsius)].compactMap { $0 }
        case .freqAndTemp:
            parts = [sample?.pCoreGHzText, degrees(temps?.socCelsius)]
                .compactMap { $0 }
        }
        var title = parts.isEmpty ? controller.profile.title
                                  : parts.joined(separator: " · ")

        // Sotto limitazione si aggiunge quanto si sta perdendo: "1.19 GHz" da
        // solo non dice niente a chi non ricorda che il tetto e' 3.50.
        if throttling, let fraction = sample?.pCoreCeilingFraction {
            title += String(format: "  %.0f%%", fraction * 100)
        }
        if controller.keepAwake.isActive {
            // Marcatore compatto: con due funzioni in un solo elemento serve
            // capire a colpo d'occhio se la sveglia e' attiva.
            title += " ☕"
        }
        button.title = " " + title
        button.toolTip = tooltip(sample: sample, pressure: pressure)
    }

    private func tooltip(sample: PowerSample?, pressure: ThermalPressure) -> String {
        var lines = ["Watt - profilo \(controller.profile.title)"]
        if let summary = sample?.pCoreSummary { lines.append("P-core: \(summary)") }
        lines.append("Pressione termica: \(pressure.label)")
        if pressure.isThrottling {
            lines.append("Le prestazioni sono limitate dal calore.")
        }
        lines.append("Sveglia: " + keepAwakeSummary())
        if let error = controller.lastError { lines.append("Avviso: \(error)") }
        return lines.joined(separator: "\n")
    }

    private func renderProfileChecks() {
        for (profile, item) in profileItems {
            item.state = (profile == controller.profile) ? .on : .off
        }
    }

    private func renderStateRows() {
        let sample = controller.lastSample
        let pressure = sample?.thermalPressure ?? .unknown

        let temps = controller.temperatures

        var rows: [(String, String)] = []
        if pressure.isThrottling, let fraction = sample?.pCoreCeilingFraction {
            rows.append(("PRESTAZIONI LIMITATE DAL CALORE",
                         String(format: "%.0f%% del massimo", fraction * 100)))
        } else {
            rows.append(("Termico", pressure.label))
        }
        rows.append(("Temperatura SoC",
                     ThermalSensors.Summary.format(temps?.socCelsius)))
        rows.append(("P-core", sample?.pCoreSummary ?? "n/d"))
        rows.append(("Pacchetto", sample?.packageWattsText ?? "n/d"))
        rows.append(("Memoria disponibile",
                     controller.memory?.availableText ?? "n/d"))
        rows.append(("Batteria / SSD",
                     ThermalSensors.Summary.format(temps?.batteryCelsius)
                     + " / "
                     + ThermalSensors.Summary.format(temps?.storageCelsius)))

        for (index, item) in stateItems.enumerated() {
            guard index < rows.count else { item.isHidden = true; continue }
            item.isHidden = false
            let (label, value) = rows[index]
            item.attributedTitle = Self.row(label: label, value: value)
        }
    }

    /// Mostra cosa è stato rallentato e permette di farlo o disfarlo a mano.
    ///
    /// L'elenco è esplicito di proposito: un'app che con privilegi di root
    /// cambia la priorità dei processi deve dire quali, altrimenti chiede
    /// fiducia senza offrire il modo di verificarla.
    private func renderThrottle() {
        guard let submenu = throttleRoot.submenu else { return }
        submenu.autoenablesItems = false
        submenu.removeAllItems()

        let report = controller.throttleReport
        let count = report?.throttled.count ?? 0
        throttleRoot.title = count > 0
            ? String(format: "Processi rallentati: %d", count)
            : "Processi in background"

        let action = NSMenuItem(
            title: count > 0 ? "Ripristina priorità normale"
                             : "Rallenta i background che consumano",
            action: count > 0 ? #selector(restoreThrottled)
                              : #selector(throttleNow),
            keyEquivalent: "")
        action.target = self
        submenu.addItem(action)

        guard let report, !report.throttled.isEmpty else { return }
        submenu.addItem(.separator())
        let header = NSMenuItem(title: report.summary, action: nil,
                                keyEquivalent: "")
        submenu.addItem(header)
        submenu.addItem(.separator())

        for entry in report.throttled.prefix(20) {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = Self.row(
                label: entry.name,
                value: String(format: "%.0f%% · %.0f MB",
                              entry.cpuPercent, entry.memoryMB))
            submenu.addItem(item)
        }
    }

    /// Elenca ogni sensore, dal piu' caldo al piu' freddo.
    ///
    /// Si ricostruisce solo a menu aperto: un M2 Air espone una quarantina di
    /// sensori, e rifare quaranta voci ogni pochi secondi mentre nessuno
    /// guarda sarebbe lavoro buttato.
    private func renderSensors() {
        guard menu.highlightedItem != nil || sensorsRoot.submenu?.numberOfItems == 0
                || isMenuOpen else { return }
        guard let submenu = sensorsRoot.submenu else { return }
        submenu.autoenablesItems = false
        submenu.removeAllItems()

        let groups = controller.temperatures?.byCategory ?? []
        guard !groups.isEmpty else {
            submenu.addItem(NSMenuItem(title: "Nessun sensore leggibile",
                                       action: nil, keyEquivalent: ""))
            return
        }

        // Raggruppati per famiglia invece che in un unico elenco di trentanove
        // voci: "PMU tdie3" da solo non dice nulla, sotto l'intestazione SoC
        // si capisce cos'è.
        for (index, group) in groups.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            let header = NSMenuItem(title: group.0.label, action: nil,
                                    keyEquivalent: "")
            header.image = NSImage(systemSymbolName: group.0.symbolName,
                                   accessibilityDescription: nil)
            submenu.addItem(header)
            for reading in group.1 {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = Self.row(
                    label: "   " + reading.name,
                    value: String(format: "%.1f °C", reading.celsius))
                submenu.addItem(item)
            }
        }
    }

    private func renderKeepAwake() {
        keepAwakeRoot.title = "Sveglia: " + keepAwakeSummary()
        keepAwakeRoot.image = NSImage(
            systemSymbolName: controller.keepAwake.isActive
                ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil)

        for (index, item) in keepAwakeItems.enumerated() {
            item.state = (Self.awakeModes[index] == controller.keepAwake.mode)
                ? .on : .off
        }
        displayToggle.state = controller.keepAwake.keepDisplayOn ? .on : .off
    }

    /// Descrizione della sveglia che dice anche *perche'* e' attiva: in
    /// modalita' build, quale processo la sta tenendo su, e a tempo, quanto
    /// manca.
    private func keepAwakeSummary() -> String {
        let awake = controller.keepAwake
        switch awake.mode {
        case .off:
            // Prestazioni e Massimo tengono una propria assertion: dire
            // "disattivata" mentre il Mac non puo' comunque dormire sarebbe
            // falso, ed e' il tipo di bugia che fa perdere fiducia in tutto
            // il resto di quello che il menu mostra.
            return controller.sleepPrevented
                ? "disattivata (ma il profilo impedisce la sospensione)"
                : "disattivata"
        case .indefinite:
            return "sempre attiva"
        case .duration:
            guard let remaining = awake.remaining, remaining > 0 else {
                return "scaduta"
            }
            let minutes = Int(remaining / 60) + 1
            return minutes >= 60
                ? String(format: "%dh %02dm", minutes / 60, minutes % 60)
                : "\(minutes) min"
        case .whileBuilding:
            if let process = awake.detectedProcess { return "build (\(process))" }
            return "in attesa di una build"
        }
    }

    /// Etichetta a sinistra, valore a destra in grigio: la stessa forma dei
    /// menu di sistema, ottenuta con un tab stop invece che con spazi, cosi'
    /// le colonne restano allineate a qualunque larghezza.
    private static func row(label: String, value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 260)]

        let attributed = NSMutableAttributedString(
            string: label + "\t",
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .paragraphStyle: paragraph])
        attributed.append(NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        return attributed
    }

    // MARK: - Azioni

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = PowerProfile(rawValue: raw) else { return }
        controller.apply(profile)
    }

    @objc private func selectKeepAwake(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              index < Self.awakeModes.count else { return }
        controller.setKeepAwake(Self.awakeModes[index])
    }

    @objc private func selectCadence(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Double,
              let option = Preferences.Cadence(rawValue: raw) else { return }
        Preferences.cadence = option
        poller.restart()
        render()
    }

    @objc private func selectBarDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Preferences.BarDisplay(rawValue: raw) else { return }
        Preferences.barDisplay = option
        render()
    }

    @objc private func toggleSuspension() {
        controller.toggleServiceSuspension()
    }

    @objc private func throttleNow() {
        controller.throttleNow()
    }

    @objc private func restoreThrottled() {
        controller.restoreThrottled()
    }

    @objc private func toggleAlerts() {
        Preferences.alertsEnabled.toggle()
        render()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Preferences.alertThreshold = value
        render()
    }

    @objc private func toggleDisplay() {
        controller.setKeepDisplayOn(!controller.keepAwake.keepDisplayOn)
    }

    @objc private func purgeMemory() {
        let before = controller.memory?.availableBytes ?? 0
        controller.purgeMemory { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.presentError("Memoria non liberata", detail: failure)
                return
            }
            let after = self.controller.memory?.availableBytes ?? 0
            // Il guadagno si mostra solo se c'e' stato: un avviso che
            // annuncia "liberati 0,00 GB" e' peggio di nessun avviso.
            if after > before {
                let freed = MemoryReader.Snapshot.gigabytes(after - before)
                self.statusItem.button?.toolTip = "Watt - liberati \(freed)"
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        Preferences.launchAtLogin.toggle()
        launchItem.state = Preferences.launchAtLogin ? .on : .off
    }

    @objc private func uninstallHelper() {
        let alert = NSAlert()
        alert.messageText = "Ripristinare le impostazioni originali?"
        alert.informativeText =
            "Watt rimettera' Low Power Mode, Spotlight, Time Machine e la "
            + "priorita' dei processi come erano prima della prima "
            + "esecuzione, poi rimuovera' l'helper privilegiato."
        alert.addButton(withTitle: "Ripristina e rimuovi")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        helper.uninstall { [weak self] failure in
            guard let self else { return }
            self.controller.apply(.automatico)
            if let failure {
                self.presentError("Ripristino incompleto", detail: failure)
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func presentError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Ho capito")
        alert.runModal()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        controller.adoptExternalProfileChange()
        controller.refreshAllSensors()
        poller.setForeground(true)
        controller.refreshState()
        // I watt costano un powermetrics: si chiedono solo mentre qualcuno
        // sta effettivamente guardando il menu.
        controller.refreshPower()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        poller.setForeground(false)
    }
}
