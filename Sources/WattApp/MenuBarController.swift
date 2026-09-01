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
    private var diagnosisRoot = NSMenuItem()
    private var alertsToggle = NSMenuItem()
    private let chartView = TemperatureChartView()
    private let chartItem = NSMenuItem()
    private var throttleRoot = NSMenuItem()
    private var batteryRoot = NSMenuItem()
    private let batteryChart = BatteryChartView()
    private let batteryChartItem = NSMenuItem()

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

        // Al passaggio chiaro/scuro si riscrive tutto da capo.
        //
        // L'elemento in barra viene aggiornato solo quando simbolo, tinta o
        // testo cambiano: e' cio' che tiene il costo dell'app sotto il punto
        // percentuale. Ma un cambio di tema non cambia nessuno dei tre, e
        // senza questo avviso l'elemento resterebbe con il disegno del tema
        // precedente fino al primo valore diverso.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateAppearance() }
        }

        poller.start()
        render()
    }

    // MARK: - Costruzione

    /// Riga di diagnosi in cima al menu, con il rimedio a portata di clic.
    ///
    /// Sta prima dei profili perche' e' l'informazione che serve per primo:
    /// quale delle cause possibili ti sta rallentando adesso. Quattro volte su
    /// cinque non e' quella che immagini, e nessun profilo la risolve.
    /// Porta il grafico alla larghezza del menu, una volta per apertura.
    ///
    /// Il trucco e' azzerarlo prima di misurare: `menu.size` si calcola sulle
    /// voci presenti, grafico compreso, quindi leggendola con il grafico gia'
    /// largo si otterrebbe la larghezza che il grafico stesso ha imposto. Fatto
    /// a ogni disegno invece che all'apertura, questo diventa una retroazione
    /// che allarga il menu fino a coprire lo schermo.
    private func stretchChartToMenuWidth() {
        chartView.frame.size.width = 1
        let width = menu.size.width
        guard width > 1 else { return }
        chartView.frame.size.width = width
        chartView.needsDisplay = true
    }

    private func renderDiagnosis() {
        guard let submenu = diagnosisRoot.submenu else { return }
        submenu.autoenablesItems = false
        submenu.removeAllItems()

        let findings = controller.findings
        guard let first = findings.first else {
            diagnosisRoot.title = L("Diagnosing…")
            diagnosisRoot.image = NSImage(systemSymbolName: "stethoscope",
                                          accessibilityDescription: nil)
            return
        }

        // Il titolo va accorciato: una voce di menu larga quanto la frase
        // piu' lunga costringe tutte le altre alla stessa larghezza, e il
        // menu diventa una parete. Il testo intero resta nel sottomenu.
        diagnosisRoot.title = Self.shortened(first.title, limit: 34)
        diagnosisRoot.image = NSImage(systemSymbolName: first.severity.symbolName,
                                      accessibilityDescription: nil)

        for (index, finding) in findings.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }

            let header = NSMenuItem(title: finding.title, action: nil,
                                    keyEquivalent: "")
            header.image = NSImage(systemSymbolName: finding.severity.symbolName,
                                   accessibilityDescription: nil)
            submenu.addItem(header)

            for line in [finding.measured, finding.advice].filter({ !$0.isEmpty }) {
                for chunk in Self.wrapped(line) {
                    let item = NSMenuItem(title: "    " + chunk, action: nil,
                                          keyEquivalent: "")
                    item.attributedTitle = NSAttributedString(
                        string: "    " + chunk,
                        attributes: [
                            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ])
                    submenu.addItem(item)
                }
            }

            if case .none = finding.remedy {} else {
                let action = NSMenuItem(title: "    " + Self.remedyLabel(finding.remedy),
                                        action: #selector(applyRemedy(_:)),
                                        keyEquivalent: "")
                action.target = self
                action.representedObject = index
                submenu.addItem(action)
            }
        }
    }

    /// Tronca a parola intera, con i puntini, per non allargare il menu.
    private static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var result = ""
        for word in text.split(separator: " ") {
            if result.count + word.count + 1 > limit - 1 { break }
            result += result.isEmpty ? String(word) : " " + word
        }
        return (result.isEmpty ? String(text.prefix(limit - 1)) : result) + "…"
    }

    private static func remedyLabel(_ remedy: Diagnosis.Remedy) -> String {
        switch remedy {
        case .switchProfile(let profile): return L("Switch to %@", profile.title)
        case .freezeServices:             return L("Freeze deferrable services")
        case .throttleBackground:         return L("Slow down background processes")
        case .none:                       return ""
        }
    }

    /// Manda a capo a 62 caratteri: una voce di menu troppo lunga viene
    /// troncata da AppKit proprio dove sta l'informazione utile.
    private static func wrapped(_ text: String, width: Int = 62) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width {
                lines.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    @objc private func applyRemedy(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              index < controller.findings.count else { return }
        controller.apply(controller.findings[index].remedy)
    }

    private func buildMenu() {
        // AppKit disabilita da se' le voci senza azione, e una voce
        // disabilitata viene disegnata semitrasparente: era il motivo per cui
        // temperature e frequenze risultavano illeggibili. Spegnendo
        // l'abilitazione automatica le righe informative restano a piena
        // opacita' pur non essendo cliccabili.
        menu.autoenablesItems = false

        diagnosisRoot = NSMenuItem(title: L("Diagnosing…"), action: nil,
                                   keyEquivalent: "")
        diagnosisRoot.submenu = NSMenu()
        menu.addItem(diagnosisRoot)
        menu.addItem(.separator())

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
        for _ in 0..<7 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            menu.addItem(item)
            stateItems.append(item)
        }

        menu.addItem(.separator())
        chartView.frame = NSRect(x: 0, y: 0, width: 300, height: 108)
        chartItem.view = chartView
        menu.addItem(chartItem)

        // Voci di secondo piano dentro due sottomenu.
        //
        // A furia di aggiungere funzioni il menu era arrivato a venti righe:
        // una parete che costringe a leggere tutto per trovare una cosa. In
        // primo piano restano lo stato e le azioni frequenti; il resto sta un
        // livello sotto, dove non ingombra ma si trova lo stesso.
        sensorsRoot = NSMenuItem(title: L("All sensors"), action: nil, keyEquivalent: "")
        sensorsRoot.submenu = NSMenu()
        sensorsRoot.image = NSImage(systemSymbolName: "thermometer.variable",
                                    accessibilityDescription: nil)
        menu.addItem(sensorsRoot)

        // La batteria sta in un sottomenu e non fra le righe principali: e'
        // un dato che si consulta, non che si sorveglia. Cicli e capacita' a
        // piena carica si muovono di mesi, e tenerli sempre a schermo
        // occuperebbe tre righe per dire ogni volta la stessa cosa.
        batteryRoot = NSMenuItem(title: L("Battery"), action: nil, keyEquivalent: "")
        batteryRoot.submenu = NSMenu()
        batteryRoot.image = NSImage(systemSymbolName: "battery.100",
                                    accessibilityDescription: nil)
        batteryChart.frame = NSRect(x: 0, y: 0, width: 330, height: 150)
        batteryChartItem.view = batteryChart
        menu.addItem(batteryRoot)

        buildKeepAwakeSubmenu()

        // --- Azioni ---
        let actionsRoot = NSMenuItem(title: L("Actions"), action: nil, keyEquivalent: "")
        let actionsMenu = NSMenu()
        actionsMenu.autoenablesItems = false

        throttleRoot = NSMenuItem(title: L("Background processes"), action: nil,
                                  keyEquivalent: "")
        throttleRoot.submenu = NSMenu()
        actionsMenu.addItem(throttleRoot)

        suspendItem = NSMenuItem(title: L("Freeze deferrable services"),
                                 action: #selector(toggleSuspension),
                                 keyEquivalent: "")
        suspendItem.target = self
        suspendItem.toolTip = L("Stops Spotlight indexing, photo analysis, "
                              + "backups and updates with SIGSTOP. They resume "
                              + "exactly where they left off, and unfreeze by "
                              + "themselves after half an hour.")
        actionsMenu.addItem(suspendItem)

        let purge = NSMenuItem(title: L("Free memory now"),
                               action: #selector(purgeMemory), keyEquivalent: "")
        purge.target = self
        purge.toolTip = L("Runs purge: frees inactive memory. It also evicts "
                        + "the file cache, so it is worth doing before a "
                        + "build, not during one.")
        actionsMenu.addItem(purge)
        actionsRoot.submenu = actionsMenu
        actionsRoot.image = NSImage(systemSymbolName: "wand.and.sparkles",
                                    accessibilityDescription: nil)
        menu.addItem(actionsRoot)

        // --- Impostazioni ---
        let settingsRoot = NSMenuItem(title: L("Settings"), action: nil,
                                      keyEquivalent: "")
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false

        let alertsRoot = NSMenuItem(title: L("Temperature alerts"), action: nil,
                                    keyEquivalent: "")
        let alertsMenu = NSMenu()
        alertsMenu.autoenablesItems = false
        alertsToggle = NSMenuItem(title: L("Warn me when it gets hot"),
                                  action: #selector(toggleAlerts), keyEquivalent: "")
        alertsToggle.target = self
        alertsMenu.addItem(alertsToggle)
        alertsMenu.addItem(.separator())
        for threshold in TemperatureAlert.thresholds {
            let item = NSMenuItem(title: L("above %.0f °C", threshold),
                                  action: #selector(selectThreshold(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = threshold
            alertsMenu.addItem(item)
            thresholdItems.append(item)
        }
        alertsRoot.submenu = alertsMenu
        settingsMenu.addItem(alertsRoot)

        let cadenceRoot = NSMenuItem(title: L("Refresh rate"), action: nil,
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
        cadenceRoot.toolTip = L("Measured on an M2 Air with the menu closed: "
                              + "taking the readings costs about 0.4%% of a core. "
                              + "Redrawing the menu bar every time the number "
                              + "changes costs three times as much. Slowing the "
                              + "refresh helps less than choosing a value that "
                              + "changes rarely.")
        settingsMenu.addItem(cadenceRoot)

        let displayRoot = NSMenuItem(title: L("Show in menu bar"), action: nil,
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
        settingsMenu.addItem(displayRoot)

        settingsMenu.addItem(.separator())
        launchItem = NSMenuItem(title: L("Open at login"),
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launchItem.target = self
        settingsMenu.addItem(launchItem)

        let uninstall = NSMenuItem(title: L("Restore settings and remove helper"),
                                   action: #selector(uninstallHelper),
                                   keyEquivalent: "")
        uninstall.target = self
        settingsMenu.addItem(uninstall)

        settingsRoot.submenu = settingsMenu
        settingsRoot.image = NSImage(systemSymbolName: "gearshape",
                                     accessibilityDescription: nil)
        menu.addItem(settingsRoot)

        menu.addItem(.separator())

        let explain = NSMenuItem(title: L("What the profiles do…"),
                                 action: #selector(explainProfiles),
                                 keyEquivalent: "")
        explain.target = self
        menu.addItem(explain)

        let quit = NSMenuItem(title: L("Quit"), action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Le quattro descrizioni a confronto, in una finestrella.
    ///
    /// Stavano nei tooltip, dove non le legge nessuno, e come righe sempre a
    /// schermo allargavano il menu quanto la frase piu' lunga. Qui si leggono
    /// una volta e non ingombrano mai piu'.
    @objc private func explainProfiles() {
        let alert = NSAlert()
        alert.messageText = L("What the profiles do")
        alert.informativeText = PowerProfile.allCases
            .map { "\($0.title.uppercased())\n\($0.explanation)" }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
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
                item.toolTip = L("Keeps the Mac awake while xcodebuild, "
                               + "swift-frontend, cargo, ninja, ffmpeg and "
                               + "similar tools are running.")
            }
            submenu.addItem(item)
            keepAwakeItems.append(item)
        }

        submenu.addItem(.separator())
        displayToggle = NSMenuItem(title: L("Keep the display on too"),
                                   action: #selector(toggleDisplay),
                                   keyEquivalent: "")
        displayToggle.target = self
        submenu.addItem(displayToggle)

        keepAwakeRoot = NSMenuItem(title: L("Keep awake"), action: nil, keyEquivalent: "")
        keepAwakeRoot.submenu = submenu
        keepAwakeRoot.image = NSImage(systemSymbolName: "cup.and.saucer",
                                      accessibilityDescription: nil)
        menu.addItem(keepAwakeRoot)
    }

    // MARK: - Rendering

    /// `true` dopo il primo disegno completo del menu.
    ///
    /// Serve a distinguere "il menu e' chiuso, non ridisegnarlo" da "il menu
    /// non e' mai stato costruito": senza, alla prima apertura si vedrebbe
    /// un menu vuoto per la frazione di secondo che passa prima che una
    /// lettura asincrona faccia scattare il disegno.
    private var menuRendered = false

    /// Cosa si ridisegna a ogni giro e cosa no.
    ///
    /// A menu chiuso l'unica cosa visibile e' l'elemento in barra: tutto il
    /// resto — sette righe di testo attribuito, tre sottomenu ricostruiti da
    /// zero, i segni di spunta di quattordici voci — veniva rifatto una
    /// volta ogni due secondi per nessuno. Fra queste c'era anche
    /// `Preferences.launchAtLogin`, che dietro l'apparenza di una proprieta'
    /// e' un dialogo sincrono con `smd`: il pezzo piu' caro dell'intero
    /// giro, pagato di continuo per aggiornare una spunta dentro un
    /// sottomenu chiuso.
    private func render() {
        renderStatusItem()
        guard isMenuOpen || !menuRendered else { return }
        menuRendered = true
        renderDiagnosis()
        renderProfileChecks()
        renderStateRows()
        renderKeepAwake()
        renderSensors()
        renderBattery()
        renderThrottle()
        let suspended = controller.suspendedServices
        suspendItem.title = suspended.isEmpty
            ? L("Freeze deferrable services")
            : L("Resume %d frozen services", suspended.count)
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

    /// Butta via lo stato di "gia' disegnato" e ridisegna tutto.
    private func invalidateAppearance() {
        lastSymbol = nil
        lastTint = nil
        statusItem.button?.title = ""
        menuRendered = false
        render()
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let sample = controller.lastSample
        let pressure = sample?.thermalPressure ?? .unknown
        let severity = sample?.thermalSeverity ?? .none

        // Quando il sistema limita le prestazioni l'elemento cambia colore e
        // simbolo. Un'icona che resta identica mentre perdi il 60% del clock
        // e' inutile: il senso di questa app e' che quel momento si veda.
        //
        // Tre stati e non due. Una "Moderata" **misurata** e' gia' un
        // `throttle: yes` per asitop e merita di essere detta, ma con un
        // termometro arancione, non con il triangolo rosso che si tiene per
        // "Pesante": se il segnale piu' grave e quello piu' lieve hanno lo
        // stesso aspetto, il piu' grave smette di significare qualcosa.
        let symbol: String
        let tint: NSColor
        switch severity {
        case .alarm:
            symbol = "exclamationmark.triangle.fill"
            tint = .systemRed
        case .notice:
            symbol = "thermometer.medium"
            tint = .systemOrange
        case .none:
            symbol = controller.profile.symbolName
            // Bianco esplicito, non `labelColor`. Il colore di sistema segue
            // l'aspetto dell'applicazione, non quello della barra: con Mac in
            // modo chiaro e barra scura (uno sfondo scuro basta) il titolo
            // veniva disegnato nero su nero e spariva. La barra dei menu e'
            // scura in tutti i casi in cui questa app ha qualcosa da dire.
            tint = .white
        }
        let throttling = severity == .alarm

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
        // Simbolo e cifre in una sola immagine, disegnata qui.
        //
        // La barra dei menu non lascia decidere il colore del titolo: quello
        // di un `NSStatusBarButton` viene ridisegnato con il colore
        // dell'aspetto della barra, e `attributedTitle` e `contentTintColor`
        // vengono scavalcati senza dire niente. E' la ragione per cui le
        // cifre restavano nere su barra chiara nonostante il bianco imposto.
        //
        // Un'immagine con `isTemplate = false` arriva a schermo esattamente
        // come e' stata disegnata: nessuno la ricolora. Costa un disegno per
        // ogni cambio di testo, quindi si ridisegna solo quando testo,
        // simbolo o colore cambiano davvero.
        if title != lastTitle || symbol != lastSymbol || tint != lastTint {
            lastTitle = title
            lastSymbol = symbol
            lastTint = tint
            button.image = Self.barImage(
                symbol: symbol, title: title, color: tint,
                accessibility: controller.profile.title)
            button.imagePosition = .imageOnly
            button.title = ""
            // Con un'immagine non-template la tinta non si applica, ma
            // lasciarla impostata confonde chi legge il codice dopo.
            button.contentTintColor = nil
        }

        // Il tooltip non entra nel disegno, quindi non costa un ridisegno:
        // si riscrive solo quando cambia, per non sporcare invano lo stato
        // della vista.
        let hint = tooltip(sample: sample, pressure: pressure)
        if hint != button.toolTip { button.toolTip = hint }
    }

    /// Ultimo contenuto disegnato in barra. Ridisegnare l'immagine e'
    /// l'operazione piu' cara del giro di aggiornamento, e per la gran parte
    /// dei giri non e' cambiato niente: tre confronti costano meno.
    private var lastSymbol: String?
    private var lastTint: NSColor?
    private var lastTitle: String?

    /// Compone simbolo e cifre in un'unica immagine non-template.
    ///
    /// Non-template e' il punto di tutto: un'immagine template viene
    /// ricolorata dalla barra dei menu secondo il proprio aspetto, ed e'
    /// esattamente il comportamento da cui questo codice si sta sottraendo.
    private static func barImage(symbol: String,
                                 title: String,
                                 color: NSColor,
                                 accessibility: String) -> NSImage? {
        let font = NSFont.menuBarFont(ofSize: 0)
        let text = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()

        let glyph = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: accessibility)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: font.pointSize,
                                            weight: .regular))
        let glyphSize = glyph?.size ?? .zero
        let gap: CGFloat = glyphSize.width > 0 && !title.isEmpty ? 4 : 0
        let size = NSSize(width: ceil(glyphSize.width + gap + textSize.width),
                          height: ceil(max(glyphSize.height, textSize.height)))
        guard size.width > 0, size.height > 0 else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()
        if let glyph {
            let box = NSRect(x: 0,
                             y: ((size.height - glyphSize.height) / 2).rounded(),
                             width: glyphSize.width, height: glyphSize.height)
            glyph.draw(in: box)
            // Il simbolo arriva nero: lo si ricolora dipingendo sopra solo
            // dove ha lasciato pixel. `sourceAtop` fa esattamente questo, e
            // resta dentro il riquadro del simbolo senza toccare le cifre.
            color.set()
            box.fill(using: .sourceAtop)
        }
        text.draw(at: NSPoint(x: glyphSize.width + gap,
                              y: ((size.height - textSize.height) / 2).rounded()))
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = accessibility
        return image
    }

    private func tooltip(sample: PowerSample?, pressure: ThermalPressure) -> String {
        var lines = [L("Watt — %@ profile", controller.profile.title)]
        if let summary = sample?.pCoreSummary { lines.append(L("P-cores: %@", summary)) }
        // La fonte va detta: "Moderata" da powermetrics e "Moderata" da
        // ProcessInfo sono due affermazioni con un grado di fiducia diverso,
        // e chi legge ha il diritto di sapere quale delle due sta guardando.
        lines.append(L("Thermal pressure: %@ (%@)", pressure.label,
                       (sample?.thermalPressureSource ?? .unknown).label))
        if sample?.thermalSeverity == .alarm {
            lines.append(L("Performance is being limited by heat."))
        } else if sample?.thermalSeverity == .notice {
            lines.append(L("The system has started limiting something."))
        }
        if let battery = controller.batterySnapshot,
           let percent = battery.chargePercent, let health = battery.healthPercent {
            lines.append(L("Battery: %d%% · health %.0f%% · %d cycles",
                           percent, health, battery.cycleCount ?? 0))
        }
        lines.append(L("Keep awake: %@", keepAwakeSummary()))
        if let error = controller.lastError { lines.append(L("Warning: %@", error)) }
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
        if sample?.thermalSeverity == .alarm, let fraction = sample?.pCoreCeilingFraction {
            rows.append((L("Limited by heat"),
                         L("%.0f%% of maximum", fraction * 100)))
        } else {
            // Una stima marcata come tale non e' la stessa cosa di una
            // misura, e il menu deve poterle distinguere senza aprire un
            // tooltip: "Nominale (stima)" e "Nominale" dicono due cose
            // diverse su quanto fidarsi.
            let source = sample?.thermalPressureSource ?? .unknown
            rows.append((L("Thermal"), source.isMeasured
                ? pressure.label
                : L("%@ (estimate)", pressure.label)))
        }
        // "Picco" e non "temperatura": e' il massimo fra i sensori del die,
        // che e' il numero che decide quando il sistema comincia a limitare.
        // La media sta nel grafico, dove serve a dire se scalda tutto il SoC
        // o un punto solo.
        rows.append((L("SoC peak"),
                     ThermalSensors.Summary.format(temps?.socCelsius)))
        rows.append((L("P-cores"), sample?.pCoreSummary ?? "n/d"))
        rows.append((L("Package"), sample?.packageWattsText ?? "n/d"))
        rows.append((L("Memory available"),
                     controller.memory?.availableText ?? "n/d"))
        if let battery = controller.batterySnapshot,
           let percent = battery.chargePercent {
            var text = "\(percent)%"
            if let health = battery.healthPercent {
                text += L(" · health %.0f%%", health)
            }
            rows.append((L("Battery"), text))
        }
        rows.append((L("Battery / SSD"),
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
            ? L("Slowed down: %d processes", count)
            : L("Background processes")

        let action = NSMenuItem(
            title: count > 0 ? L("Restore normal priority")
                             : L("Slow down heavy background processes"),
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
            submenu.addItem(NSMenuItem(title: L("No readable sensors"),
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

    /// Il pannello batteria: capacita', usura, elettrico, alimentatore.
    ///
    /// Le grandezze sono quelle che mostra coconutBattery, lette dallo stesso
    /// posto — il nodo `AppleSmartBattery` del registro IO — piu' due che
    /// coconutBattery non mostra e che qui hanno senso: la potenza che entra
    /// nel Mac dall'alimentatore, che e' il consumo del **sistema intero**
    /// contro quello del solo SoC dato da powermetrics, e la perdita
    /// dell'alimentatore.
    ///
    /// Si ricostruisce solo a menu aperto: sono una ventina di voci per un
    /// dato che si muove di mesi.
    private func renderBattery() {
        guard let submenu = batteryRoot.submenu else { return }

        guard let battery = controller.batterySnapshot else {
            batteryRoot.title = L("Battery")
            if submenu.numberOfItems == 0 {
                submenu.addItem(NSMenuItem(title: L("No battery"), action: nil,
                                           keyEquivalent: ""))
            }
            return
        }

        // Il titolo si aggiorna sempre: e' l'unica parte visibile a menu
        // chiuso, e ricostruire venti voci per tenerlo fresco sarebbe uno
        // spreco.
        var title = L("Battery")
        if let percent = battery.chargePercent { title += " \(percent)%" }
        if let health = battery.healthPercent {
            title += String(format: " · %.0f%%", health)
        }
        batteryRoot.title = title
        batteryRoot.image = NSImage(systemSymbolName: batterySymbol(battery),
                                    accessibilityDescription: nil)

        guard isMenuOpen || submenu.numberOfItems == 0 else { return }
        submenu.autoenablesItems = false
        submenu.removeAllItems()

        batteryChart.snapshot = battery
        batteryChart.trend = controller.batteryTrend
        batteryChart.monthsToEighty = controller.batteryMonthsToEighty
        batteryChart.trendIsMeaningful = controller.batteryTrendIsMeaningful
        submenu.addItem(batteryChartItem)
        submenu.addItem(.separator())

        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = Self.row(label: label, value: value)
            submenu.addItem(item)
        }

        add(L("Charge"), battery.chargePercent.map { "\($0)%" })
        add(L("State"), battery.stateLabel)
        add(L("Time"), battery.timeRemainingText)

        submenu.addItem(.separator())
        // Due percentuali di salute, entrambe vere, calcolate su due campi
        // diversi del gas gauge. Mostrarne una sola e nascondere l'altra
        // significa lasciare l'utente davanti a due numeri discordi — il
        // proprio e quello di Impostazioni di Sistema — senza spiegazione.
        if let health = battery.healthPercent, let full = battery.fullChargeCapacityMAh,
           let design = battery.designCapacityMAh {
            add(L("Health"), String(format: "%.1f%%  (%d / %d mAh)",
                                    health, full, design))
        }
        if let apple = battery.applePercent {
            add(L("macOS “Maximum Capacity”"), "\(apple)%")
        }
        if let cycles = battery.cycleCount {
            add(L("Cycles"), battery.designCycleCount.map { "\(cycles) / \($0)" }
                ?? "\(cycles)")
        }
        add(L("Condition"), battery.condition)
        if let design = battery.designWattHours, let full = battery.fullChargeWattHours,
           let now = battery.remainingWattHours {
            add(L("Energy (approx.)"),
                String(format: "%.1f / %.1f / %.1f Wh", now, full, design))
        }
        if let degradation = controller.batteryDegradation {
            add(L("Measured loss"),
                L("%.2f%% in %.0f days · %d cycles",
                  degradation.points, degradation.days, degradation.cycles))
        }

        submenu.addItem(.separator())
        add(L("Voltage"), battery.voltageMV.map {
            String(format: "%.2f V", Double($0) / 1000) })
        add(L("Current"), (battery.amperageMA ?? battery.instantAmperageMA)
            .map { "\($0) mA" })
        add(L("Battery power"), battery.batteryWatts.map {
            String(format: "%+.2f W", $0) })
        add(L("Temperature"),
            controller.temperatures?.batteryCelsius.map {
                String(format: "%.1f °C", $0) })

        // Consumo del sistema intero, non del solo SoC: sono due grandezze
        // diverse e vanno etichettate come tali, altrimenti sembra che
        // l'app si contraddica con la riga "Pacchetto" del menu principale.
        if battery.systemWatts != nil || battery.adapterName != nil {
            submenu.addItem(.separator())
            add(L("System from the wall"), battery.systemWatts.map {
                String(format: "%.1f W", $0) })
            add(L("Adapter loss"), battery.adapterEfficiencyLossMW.map {
                String(format: "%.1f W", Double($0) / 1000) })
            add(L("Adapter"), battery.adapterName)
            if let watts = battery.adapterWatts {
                add(L("Negotiated"), battery.adapterVoltageMV.map {
                    String(format: "%d W  (%.0f V × %.2f A)", watts,
                           Double($0) / 1000,
                           Double(battery.adapterCurrentMA ?? 0) / 1000)
                } ?? "\(watts) W")
            }
        }

        submenu.addItem(.separator())
        add(L("Pack"), battery.deviceName)
        add(L("Cells"), [battery.cellVendorCode, battery.cellLotCode]
            .compactMap { $0 }.joined(separator: " · "))
        add(L("Serial"), battery.serial)
        if let reason = battery.notChargingReason, reason != 0,
           battery.isCharging != true {
            // Codice grezzo, non tradotto: i bit non sono documentati, e
            // battezzarli "carica ottimizzata" a naso sarebbe inventare una
            // misura. Chi indaga puo' cercarlo; l'app non finge di saperlo.
            add(L("Not charging (raw code)"), String(format: "0x%X", reason))
        }
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging == true { return "battery.100.bolt" }
        switch battery.chargePercent ?? 100 {
        case ..<10:  return "battery.0"
        case ..<35:  return "battery.25"
        case ..<60:  return "battery.50"
        case ..<85:  return "battery.75"
        default:     return "battery.100"
        }
    }

    private func renderKeepAwake() {
        keepAwakeRoot.title = L("Keep awake: %@", keepAwakeSummary())
        // La precisazione sul profilo che impedisce comunque la sospensione
        // stava nel titolo e da sola allargava il menu di meta': come tooltip
        // resta disponibile senza costare larghezza a tutte le altre voci.
        keepAwakeRoot.toolTip = controller.sleepPrevented && !controller.keepAwake.isActive
            ? L("The current profile prevents sleep anyway.") : nil
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
            return L("off")
        case .indefinite:
            return L("always on")
        case .duration:
            guard let remaining = awake.remaining, remaining > 0 else {
                return L("expired")
            }
            let minutes = Int(remaining / 60) + 1
            return minutes >= 60
                ? String(format: "%dh %02dm", minutes / 60, minutes % 60)
                : L("%d min", minutes)
        case .whileBuilding:
            if let process = awake.detectedProcess { return L("build (%@)", process) }
            return L("waiting for a build")
        }
    }

    /// Etichetta a sinistra, valore a destra in grigio: la stessa forma dei
    /// menu di sistema, ottenuta con un tab stop invece che con spazi, cosi'
    /// le colonne restano allineate a qualunque larghezza.
    private static func row(label: String, value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // 260 punti: e' il tab stop che decide la larghezza minima del menu,
        // perche' ogni riga informativa arriva almeno fin li'. Allargarlo per
        // far stare un'etichetta lunga gonfia l'intero menu.
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 260)]

        // Il colore va dichiarato anche sull'etichetta.
        //
        // Un `NSAttributedString` senza `.foregroundColor` non eredita il
        // colore del tema: ripiega sul nero. In modo chiaro il nero e' il
        // colore giusto per caso, e il difetto resta invisibile; al primo
        // passaggio a modo scuro la meta' sinistra di ogni riga diventa nera
        // su fondo nero. Il valore a destra il colore ce l'aveva gia', ed e'
        // il motivo per cui sparivano le etichette e non i numeri.
        let attributed = NSMutableAttributedString(
            string: label + "\t",
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: NSColor.labelColor,
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
                self.presentError(L("Memory not freed"), detail: failure)
                return
            }
            let after = self.controller.memory?.availableBytes ?? 0
            // Il guadagno si mostra solo se c'e' stato: un avviso che
            // annuncia "liberati 0,00 GB" e' peggio di nessun avviso.
            if after > before {
                let freed = MemoryReader.Snapshot.gigabytes(after - before)
                self.statusItem.button?.toolTip = L("Watt — freed %@", freed)
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        Preferences.launchAtLogin.toggle()
        launchItem.state = Preferences.launchAtLogin ? .on : .off
    }

    @objc private func uninstallHelper() {
        let alert = NSAlert()
        alert.messageText = L("Restore the original settings?")
        alert.informativeText =
            L("Watt will put Low Power Mode, Spotlight, Time Machine and process "
            + "priorities back the way they were before its first run, then "
            + "remove the privileged helper.")
        alert.addButton(withTitle: L("Restore and remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        helper.uninstall { [weak self] failure in
            guard let self else { return }
            self.controller.apply(.automatico)
            if let failure {
                self.presentError(L("Restore incomplete"), detail: failure)
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func presentError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        stretchChartToMenuWidth()
        controller.adoptExternalProfileChange()
        controller.refreshAllSensors()
        controller.refreshDiagnosis()
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
