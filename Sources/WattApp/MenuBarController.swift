import AppKit
import WattKit

/// L'elemento in menu bar e il suo menu.
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
        for _ in 0..<5 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            stateItems.append(item)
        }

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Apri all'avvio",
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.target = self
        launch.identifier = NSUserInterfaceItemIdentifier("launch")
        menu.addItem(launch)

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

    // MARK: - Rendering

    private func render() {
        renderStatusItem()
        renderProfileChecks()
        renderStateRows()
        renderLaunchItem()
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let sample = controller.lastSample
        let pressure = sample?.thermalPressure ?? .unknown

        // Quando il sistema sta limitando le prestazioni l'icona lo dice:
        // e' l'informazione che nessuna interfaccia di sistema mostra, e il
        // motivo principale per cui questa app esiste su un Mac senza ventola.
        let symbol = pressure.isThrottling
            ? pressure.symbolName
            : controller.profile.symbolName
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: controller.profile.title)
        button.imagePosition = .imageLeading

        if let ghz = sample?.pCoreGHzText {
            button.title = " \(ghz)"
        } else {
            button.title = " \(controller.profile.title)"
        }
        button.toolTip = tooltip(sample: sample, pressure: pressure)
    }

    private func tooltip(sample: PowerSample?, pressure: ThermalPressure) -> String {
        var lines = ["Watt - profilo \(controller.profile.title)"]
        if let summary = sample?.pCoreSummary {
            lines.append("P-core: \(summary)")
        }
        lines.append("Pressione termica: \(pressure.label)")
        if pressure.isThrottling {
            lines.append("Le prestazioni sono limitate dal calore.")
        }
        if let error = controller.lastError {
            lines.append("Avviso: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func renderProfileChecks() {
        for (profile, item) in profileItems {
            item.state = (profile == controller.profile) ? .on : .off
        }
    }

    private func renderStateRows() {
        let sample = controller.lastSample
        let state = controller.lastState
        let pressure = sample?.thermalPressure ?? .unknown

        var rows: [(String, String)] = []
        rows.append(("Termico", pressure.label
            + (pressure.isThrottling ? "  - prestazioni limitate" : "")))
        rows.append(("P-core", sample?.pCoreSummary ?? "n/d"))
        rows.append(("Pacchetto", sample?.packageWattsText ?? "n/d"))
        rows.append(("Low Power Mode",
                     state.map { $0.lowPowerMode ? "attivo" : "spento" } ?? "n/d"))
        rows.append(("Spotlight",
                     state.map { $0.spotlightIndexing ? "attivo" : "in pausa" } ?? "n/d"))

        for (index, item) in stateItems.enumerated() {
            guard index < rows.count else { item.isHidden = true; continue }
            item.isHidden = false
            let (label, value) = rows[index]
            item.attributedTitle = Self.row(label: label, value: value)
        }
    }

    /// Etichetta a sinistra, valore a destra in grigio: la stessa forma dei
    /// menu di sistema, ottenuta con un tab stop invece che con spazi, cosi'
    /// le colonne restano allineate a qualunque larghezza.
    private static func row(label: String, value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 240)]

        let attributed = NSMutableAttributedString(
            string: label + "\t",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph,
            ])
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

    private func renderLaunchItem() {
        guard let item = menu.items.first(where: {
            $0.identifier?.rawValue == "launch"
        }) else { return }
        item.state = Preferences.launchAtLogin ? .on : .off
    }

    // MARK: - Azioni

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = PowerProfile(rawValue: raw) else { return }

        if case .needsApproval = helper.installState {
            presentApprovalRequest()
        }
        controller.apply(profile)
    }

    @objc private func toggleLaunchAtLogin() {
        Preferences.launchAtLogin.toggle()
        renderLaunchItem()
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentApprovalRequest() {
        let alert = NSAlert()
        alert.messageText = "Watt ha bisogno della tua approvazione"
        alert.informativeText =
            "L'helper che applica le modifiche e legge i consumi va abilitato "
            + "in Impostazioni di Sistema, in Generali - Elementi login ed "
            + "estensioni. Finche' non lo abiliti, restano attivi solo i "
            + "cambiamenti che non richiedono privilegi."
        alert.addButton(withTitle: "Apri Impostazioni di Sistema")
        alert.addButton(withTitle: "Piu' tardi")
        if alert.runModal() == .alertFirstButtonReturn {
            helper.openLoginItemsSettings()
        }
    }

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
        poller.setForeground(true)
        controller.refreshState()
    }

    func menuDidClose(_ menu: NSMenu) {
        poller.setForeground(false)
    }
}
