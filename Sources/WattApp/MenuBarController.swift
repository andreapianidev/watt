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
            item.isEnabled = false
            menu.addItem(item)
            stateItems.append(item)
        }

        sensorsRoot = NSMenuItem(title: "Tutti i sensori", action: nil, keyEquivalent: "")
        sensorsRoot.submenu = NSMenu()
        sensorsRoot.image = NSImage(systemSymbolName: "thermometer.variable",
                                    accessibilityDescription: nil)
        menu.addItem(sensorsRoot)

        menu.addItem(.separator())
        buildKeepAwakeSubmenu()

        let displayRoot = NSMenuItem(title: "Mostra in barra", action: nil,
                                     keyEquivalent: "")
        let displayMenu = NSMenu()
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
        for item in barDisplayItems {
            item.state = (item.representedObject as? String
                          == Preferences.barDisplay.rawValue) ? .on : .off
        }
        launchItem.state = Preferences.launchAtLogin ? .on : .off
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let sample = controller.lastSample
        let pressure = sample?.thermalPressure ?? .unknown

        // Il throttling ha la precedenza su tutto: e' l'informazione che
        // nessuna interfaccia di sistema mostra, ed e' il motivo principale
        // per cui questa app esiste su un Mac senza ventola.
        let symbol = pressure.isThrottling
            ? pressure.symbolName
            : controller.profile.symbolName
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: controller.profile.title)
        button.imagePosition = .imageLeading

        let temperature = controller.temperatures?.socCelsius
            .map { String(format: "%.0f°", $0) }
        var parts: [String] = []
        switch Preferences.barDisplay {
        case .frequency:
            parts = [sample?.pCoreGHzText].compactMap { $0 }
        case .temperature:
            parts = [temperature].compactMap { $0 }
        case .both:
            parts = [sample?.pCoreGHzText, temperature].compactMap { $0 }
        }
        var title = parts.isEmpty ? controller.profile.title
                                  : parts.joined(separator: " · ")
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
        rows.append(("Termico", pressure.label
            + (pressure.isThrottling ? "  - limitato" : "")))
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

    /// Elenca ogni sensore, dal piu' caldo al piu' freddo.
    ///
    /// Si ricostruisce solo a menu aperto: un M2 Air espone una quarantina di
    /// sensori, e rifare quaranta voci ogni pochi secondi mentre nessuno
    /// guarda sarebbe lavoro buttato.
    private func renderSensors() {
        guard menu.highlightedItem != nil || sensorsRoot.submenu?.numberOfItems == 0
                || isMenuOpen else { return }
        guard let submenu = sensorsRoot.submenu else { return }
        submenu.removeAllItems()

        let readings = controller.temperatures?.all ?? []
        guard !readings.isEmpty else {
            let empty = NSMenuItem(title: "Nessun sensore leggibile",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for reading in readings {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = Self.row(
                label: reading.name,
                value: String(format: "%.1f °C", reading.celsius))
            submenu.addItem(item)
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
            return "disattivata"
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
                .foregroundColor: NSColor.secondaryLabelColor,
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

    @objc private func selectBarDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Preferences.BarDisplay(rawValue: raw) else { return }
        Preferences.barDisplay = option
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
