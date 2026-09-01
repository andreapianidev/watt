import Foundation
import AppKit
import ServiceManagement
import WattKit

/// Modalita' da riga di comando.
///
///     Watt --apply massimo      applica un profilo ed esce
///     Watt --status             stampa stato e consumi
///     Watt --profiles           elenca i profili
///
/// Serve a inserire Watt negli script: cambiare profilo prima di una build e
/// tornare indietro dopo e' esattamente il caso d'uso per cui l'app esiste.
/// Usa un client XPC sincrono, senza avviare NSApplication.
enum CommandLineMode {

    /// Ritorna `true` se ha gestito gli argomenti e il processo deve uscire.
    static func run() -> Bool {
        // Senza questo, in pipe stdout e' bufferizzato a blocchi e i
        // messaggi di Watt compaiono dopo l'output del comando avvolto.
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return false }

        switch command {
        case "--apply":
            guard let name = arguments.dropFirst().first,
                  let profile = PowerProfile(rawValue: name) else {
                fail("Uso: Watt --apply <\(PowerProfile.allCases.map(\.rawValue).joined(separator: "|"))>")
            }
            apply(profile)
            return true

        case "--login":
            let wanted = arguments.dropFirst().first
            guard let wanted, ["on", "off"].contains(wanted) else {
                fail("Uso: Watt --login <on|off>")
            }
            Preferences.launchAtLogin = (wanted == "on")
            print(L("open at login: %@",
                    Preferences.launchAtLogin ? L("on") : L("off")))
            return true

        case "--uninstall":
            uninstall()
            return true

        case "--suspend", "--resume":
            let suspending = command == "--suspend"
            let data: Data? = callHelper(timeout: 30) { proxy, done in
                suspending ? proxy.suspendServices { done($0) }
                           : proxy.resumeServices { done($0) }
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data,
                  let report = try? decoder.decode(SuspensionReport.self, from: data)
            else { fail(L("Helper unreachable.")) }
            if suspending {
                print(report.suspended.isEmpty
                    ? L("no deferrable service is running")
                    : L("frozen: %@", report.suspended.joined(separator: ", ")))
                if let expiry = report.expiresAt {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    print(L("they unfreeze by themselves at %@", formatter.string(from: expiry)))
                }
            } else {
                print(report.resumed.isEmpty
                    ? L("no service was frozen")
                    : L("resumed: %@", report.resumed.joined(separator: ", ")))
            }
            return true

        case "--throttle":
            // Le applicazioni con interfaccia si proteggono anche da qui:
            // l'helper si fida di questa lista, e ometterla significherebbe
            // rallentare l'editor da cui hai lanciato il comando.
            let protected = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { NSNumber(value: $0.processIdentifier) }
            let data: Data? = callHelper(timeout: 60) { proxy, done in
                proxy.throttleHeavyBackground(protectedPIDs: protected) { done($0) }
            }
            guard let data,
                  let report = try? JSONDecoder().decode(ThrottleReport.self, from: data)
            else { fail(L("Helper unreachable.")) }
            print(report.summary)
            for entry in report.throttled.prefix(20) {
                print("   " + entry.name.padding(toLength: 24, withPad: " ",
                                                 startingAt: 0)
                    + String(format: " %5.1f%%  %6.0f MB",
                             entry.cpuPercent, entry.memoryMB))
            }
            return true

        case "--unthrottle":
            _ = callHelper(timeout: 60) { proxy, done in
                proxy.restoreThrottled { done($0 ?? "") }
            } as String?
            print(L("normal priority restored"))
            return true

        case "--debug-freq":
            // Diagnostica: stampa il calcolo della frequenza passo per passo.
            guard let sampler = IOReportSampler() else { fail("IOReport non disponibile") }
            Thread.sleep(forTimeInterval: 0.5)
            let r = sampler.sample()
            print("P-core  \(r.pCoreMHz.map { String(format: "%.0f MHz", $0) } ?? "n/d")"
                + "  tetto \(r.pCoreCeilingMHz.map { String(format: "%.0f", $0) } ?? "?")")
            print("E-core  \(r.eCoreMHz.map { String(format: "%.0f MHz", $0) } ?? "n/d")")
            sampler.dumpLastComputation()
            return true

        case "--verify-freq":
            // Confronto appaiato con powermetrics, sulla stessa finestra.
            //
            // Serve a rispondere alla sola domanda che conta: il numero in
            // barra dei menu e' quello vero? powermetrics vuole root, quindi
            // il campione arriva dall'helper; la finestra di IOReport viene
            // aperta subito prima della chiamata e chiusa subito dopo, cosi'
            // le due misure guardano lo stesso intervallo.
            verifyFrequency(rounds: Int(arguments.dropFirst().first ?? "") ?? 5)
            return true

        case "--watch-temps":
            // Ripete la lettura adattiva alla cadenza dell'app e stampa,
            // per ogni giro, *quanti* sensori sono finiti nel campione.
            // Il numero di sensori e' la variabile che il grafico non
            // mostra e che pero' ne determina la media.
            watchTemperatures(seconds: Int(arguments.dropFirst().first ?? "") ?? 30)
            return true

        case "--battery":
            printBattery()
            return true

        case "--verify-pressure":
            // La verifica che rende lecito smettere di usare powermetrics
            // per la pressione termica.
            verifyPressure(rounds: Int(arguments.dropFirst().first ?? "") ?? 10)
            return true

        case "--load":
            // Generatore di carico a QoS elevata. Serve a misurare, non a
            // scaldare per il gusto di farlo: la prova precedente usava dei
            // cicli di shell, che il sistema classifica come background e
            // confina sugli E-core — il cluster P restava a 1188 MHz e
            // l'esperimento non misurava niente.
            let arguments = Array(arguments.dropFirst())
            generateLoad(threads: Int(arguments.first ?? "") ?? 0,
                         seconds: Double(arguments.dropFirst().first ?? "") ?? 60)
            return true

        case "--bench":
            // Quanto costa un giro di campionamento. Un'app che promette
            // prestazioni non puo' essere una voce di consumo, e l'unico
            // modo per saperlo e' misurarsi.
            benchmark()
            return true

        case "--diagnose":
            diagnose()
            return true

        case "--temps":
            guard let summary = ThermalSensors()?.read(), !summary.all.isEmpty else {
                fail(L("Thermal sensors are not readable on this system."))
            }
            print(String(format: L("SoC      : %@"),
                         ThermalSensors.Summary.format(summary.socCelsius)))
            print(String(format: L("battery  : %@"),
                         ThermalSensors.Summary.format(summary.batteryCelsius)))
            print(String(format: L("SSD      : %@"),
                         ThermalSensors.Summary.format(summary.storageCelsius)))
            print(L("\n%d sensors:", summary.all.count))
            for reading in summary.all {
                print("   " + reading.name.padding(toLength: 24, withPad: " ",
                                                   startingAt: 0)
                    + String(format: " %6.1f °C", reading.celsius))
            }
            return true

        case "--purge":
            let failure = callHelper { proxy, done in
                proxy.purgeMemory { done($0) }
            } as String?
            let after = MemoryReader.read()
            if let failure {
                fail("purge: \(failure)")
            }
            print(L("memory available: %@", after?.availableText ?? "n/a"))
            return true

        case "--run":
            runWrapped(Array(arguments.dropFirst()))
            return true

        case "--status":
            status()
            return true

        case "--profiles":
            for profile in PowerProfile.allCases {
                print("\(profile.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))\(profile.explanation)")
            }
            return true

        case "--help", "-h":
            printUsage()
            return true

        default:
            return false
        }
    }

    private static func printUsage() {
        print("""
        Watt - profili energetici e misura del throttling per Mac Apple Silicon

          Watt                     avvia l'app in barra dei menu
          Watt --apply <profilo>   applica un profilo ed esce
          Watt --status            stato del sistema e consumi correnti
          Watt --profiles          elenca i profili e cosa fanno
          Watt --diagnose          cosa sta limitando la macchina adesso
          Watt --temps             tutte le temperature dei sensori
          Watt --battery           salute, cicli e degrado della batteria
          Watt --verify-freq [n]   confronta IOReport con powermetrics
          Watt --verify-pressure [n]
                                   confronta la pressione termica letta dal
                                   kernel con quella di powermetrics
          Watt --load [n] [sec]    carico a QoS alta su n thread, per misurare
          Watt --bench             quanto costa un giro di campionamento
          Watt --suspend           congela i servizi differibili (SIGSTOP)
          Watt --resume            li riattiva
          Watt --throttle          rallenta i background che consumano
          Watt --unthrottle        ne ripristina la priorità normale
          Watt --purge             libera la memoria inattiva
          Watt --login <on|off>    apertura automatica all'accesso
          Watt --uninstall         ripristina le impostazioni e deregistra
          Watt --run <profilo> -- <comando ...>
                                   esegue il comando con il profilo applicato
                                   e ripristina quello precedente alla fine

        Esempio, in uno script di build:

          Watt --run massimo -- xcodebuild -scheme App build
        """)
    }

    // MARK: - Comandi

    private static func apply(_ profile: PowerProfile) {
        // La meta' non privilegiata la applica questo processo, esattamente
        // come farebbe l'app: senza, `--apply massimo` da script lascerebbe
        // fuori App Nap.
        AppNapControl.setDisabled(profile.plan.disableAppNap)

        // Salvare la scelta e' parte dell'applicarla. Senza, il sistema
        // veniva configurato ma la preferenza restava al profilo precedente:
        // la barra dei menu continuava a mostrare quello vecchio, e alla
        // prima riscrittura lo rimetteva pure in vigore. La scrittura emette
        // anche la notifica che allinea un'app gia' in esecuzione.
        Preferences.selectedProfile = profile

        // La reply dell'helper e' `nil` in caso di successo, il che
        // collide con il `nil` che `callHelper` usa per "irraggiungibile".
        // Si trasporta il successo come stringa vuota per distinguerli.
        let outcome: String? = callHelper(timeout: 90) { proxy, done in
            proxy.applyProfile(profile.rawValue) { done($0 ?? "") }
        }
        guard let outcome else {
            fail("Helper non raggiungibile. Installalo con:\n"
               + "  sudo ./scripts/install-helper.sh")
        }
        if !outcome.isEmpty {
            FileHandle.standardError.write(
                Data("applicato con errori: \(outcome)\n".utf8))
            print(L("profile: %@", profile.title))
            exit(1)
        }
        print(L("profile: %@", profile.title))

        // La sospensione inibita richiede un processo vivo che tenga
        // l'assertion: da riga di comando non c'e' nessuno a tenerla, e
        // dirlo e' meglio che lasciar credere il contrario.
        if profile.plan.preventIdleSleep {
            print(L("note: sleep stays prevented only while the app is running"))
        }
    }

    private static func status() {
        // Frequenze e stato termico non passano dall'helper: si leggono qui,
        // senza privilegi, cosi' `--status` dice qualcosa di utile anche su
        // una macchina dove l'helper non e' installato.
        let sampler = IOReportSampler()
        // IOReport lavora per differenza fra due letture: la prima e' presa
        // dall'inizializzatore, serve una breve finestra prima della seconda.
        Thread.sleep(forTimeInterval: 0.3)
        let reading = sampler?.sample()
        let pressure = ThermalPressure(
            processInfoState: ProcessInfo.processInfo.thermalState)

        let state: SystemState? = callHelper { proxy, done in
            proxy.readSystemState { data in
                done(data.flatMap { try? JSONDecoder().decode(SystemState.self, from: $0) })
            }
        }
        let sample: PowerSample? = callHelper { proxy, done in
            proxy.sampleMetrics { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                done(data.flatMap { try? decoder.decode(PowerSample.self, from: $0) })
            }
        }

        print(L("saved profile  : %@", Preferences.selectedProfile.title))

        if let reading, let mhz = reading.pCoreMHz {
            let ceiling = reading.pCoreCeilingMHz ?? 0
            print(ceiling > 0
                ? String(format: L("P-cores         : %.2f of %.2f GHz"), mhz / 1000, ceiling / 1000)
                : String(format: L("P-cores         : %.2f GHz"), mhz / 1000))
        }
        if let mhz = reading?.eCoreMHz {
            print(String(format: L("E-cores         : %.2f GHz"), mhz / 1000))
        }
        // Due fonti, e vanno mostrate entrambe quando divergono: la stima di
        // ProcessInfo e la misura di powermetrics. E' la stessa misura che
        // asitop riduce a "throttle: yes/no", e nasconderla dietro la stima
        // era il motivo per cui Watt taceva mentre asitop segnalava.
        // Tre fonti, e vanno mostrate tutte quando divergono. Il kernel e'
        // quella buona: `com.apple.system.thermalpressurelevel` e' la stessa
        // chiave notify(3) da cui legge powermetrics, ma non costa un
        // processo e non vuole root. `--verify-pressure` le confronta.
        let kernel = ThermalPressureMonitor().level
        if let kernel {
            print(L("thermal        : %@", kernel.label)
                + " (kernel: \(kernel.rawValue))"
                + (kernel.isThrottling ? L("  <- performance limited") : ""))
        }
        if let sample, let raw = sample.thermalPressureRaw {
            let measured = ThermalPressure(raw: raw)
            if kernel == nil {
                print(L("thermal        : %@", measured.label)
                    + " (powermetrics: \(raw))"
                    + (measured.isThrottling ? L("  <- performance limited") : ""))
            } else if measured != kernel {
                print("  powermetrics dice invece: \(measured.label)")
            }
        }
        if kernel == nil, sample?.thermalPressureRaw == nil {
            print(L("thermal        : %@", pressure.label)
                + (pressure.demandsAttention ? L("  <- performance limited") : "")
                + "  (stima, kernel e helper assenti)")
        } else if pressure != (kernel ?? ThermalPressure(raw: sample?.thermalPressureRaw)) {
            print(L("  ProcessInfo instead says: %@", pressure.label))
        }
        if let temps = ThermalSensors()?.read() {
            print(L("SoC temperature: %@", ThermalSensors.Summary.format(temps.socCelsius)))
            print(L("battery / SSD  : %@ / %@",
                    ThermalSensors.Summary.format(temps.batteryCelsius),
                    ThermalSensors.Summary.format(temps.storageCelsius)))
        }
        if let watts = sample?.packageWattsText {
            print(L("package        : %@", watts))
        }
        if let battery = BatteryReader.read(), let health = battery.healthPercent {
            print(String(format: L("battery        : %d%%, health %.1f%%, %d cycles"),
                         battery.chargePercent ?? 0, health,
                         battery.cycleCount ?? 0))
            if let system = battery.systemWatts {
                // Il consumo del Mac intero, schermo compreso: e' un'altra
                // grandezza rispetto ai watt del package, e va detto.
                print(String(format: L("system (wall)  : %.1f W"), system))
            }
        }
        if let state {
            print(L("low power mode : %@", state.lowPowerMode ? L("on") : L("off")))
            print(L("power nap      : %@", state.powerNap ? L("on") : L("off")))
            print(L("spotlight      : %@", state.spotlightIndexing ? L("on") : L("paused")))
            print(L("time machine   : %@", state.timeMachineAutomatic ? L("automatic") : L("paused")))
            print(L("app nap        : %@", AppNapControl.isDisabled ? L("disabled") : L("on")))
            print(L("helper         : %@", state.helperVersion))
        }
    }

    /// Tutto quello che il Mac sa della propria batteria, in stile
    /// coconutBattery.
    private static func printBattery() {
        guard let battery = BatteryReader.read() else {
            fail("Nessuna batteria leggibile su questa macchina.")
        }

        func line(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            print("   " + label.padding(toLength: max(label.count, 26),
                                        withPad: " ", startingAt: 0) + value)
        }

        print("batteria\n")
        line("carica", battery.chargePercent.map { "\($0) %" })
        line("stato", battery.stateLabel)
        line("autonomia", battery.timeRemainingText)

        print("")
        if let health = battery.healthPercent, let full = battery.fullChargeCapacityMAh,
           let design = battery.designCapacityMAh {
            line("salute", String(format: "%.1f %%   (%d / %d mAh)",
                                  health, full, design))
        }
        // I due numeri divergono per costruzione, non per errore: Apple
        // parte dalla capacita' nominale invece che da quella grezza e
        // tronca invece di arrotondare. Stamparli vicini e' l'unico modo
        // per non far sembrare che uno dei due mentisca.
        if let apple = battery.applePercent,
           let nominal = battery.nominalChargeCapacityMAh {
            line("capacita' massima (macOS)",
                 String(format: "%d %%     (%d mAh nominali)", apple, nominal))
        }
        line("cicli", battery.cycleCount.map { cycles in
            battery.designCycleCount.map { "\(cycles) / \($0)" } ?? "\(cycles)"
        })
        line("condizione", battery.condition)
        if let now = battery.remainingWattHours, let full = battery.fullChargeWattHours,
           let design = battery.designWattHours {
            line("energia (approssimata)",
                 String(format: "%.1f / %.1f / %.1f Wh   (ora / piena / progetto)",
                        now, full, design))
        }
        line("tensione nominale pacco", battery.nominalPackVolts.map {
            String(format: "%.2f V  (%d celle in serie, derivata)",
                   $0, battery.seriesCells ?? 0) })

        print("")
        line("tensione", battery.voltageMV.map {
            String(format: "%.3f V", Double($0) / 1000) })
        line("corrente", (battery.amperageMA ?? battery.instantAmperageMA)
            .map { "\($0) mA" })
        line("potenza batteria", battery.batteryWatts.map {
            String(format: "%+.2f W", $0) })
        line("temperatura", ThermalSensors()?.read().batteryCelsius.map {
            String(format: "%.1f °C", $0) })

        print("")
        line("sistema dalla presa", battery.systemWatts.map {
            String(format: "%.2f W", $0) })
        line("perdita alimentatore", battery.adapterEfficiencyLossMW.map {
            String(format: "%.2f W", Double($0) / 1000) })
        line("alimentatore", battery.adapterName)
        line("potenza negoziata", battery.adapterWatts.map { "\($0) W" })
        line("uscita alimentatore", battery.adapterVoltageMV.map {
            String(format: "%.1f V × %.2f A", Double($0) / 1000,
                   Double(battery.adapterCurrentMA ?? 0) / 1000) })
        line("costruttore", battery.adapterManufacturer)
        line("seriale alimentatore", battery.adapterSerial)

        print("")
        line("pacco", battery.deviceName)
        line("celle", [battery.cellVendorCode, battery.cellLotCode]
            .compactMap { $0 }.joined(separator: "  lotto "))
        line("firmware", battery.firmwareVersion)
        line("revisione hardware", battery.hardwareRevision)
        line("revisione celle", battery.cellRevision)
        line("seriale", battery.serial)
        if let reason = battery.notChargingReason, reason != 0,
           battery.isCharging != true {
            line("codice non-in-carica", String(format: "0x%X (non decodificato)",
                                                reason))
        }
    }

    /// Analizza e stampa cosa sta limitando la macchina.
    private static func diagnose() {
        let sampler = IOReportSampler()
        Thread.sleep(forTimeInterval: 0.3)
        var sample = PowerSample()
        if let reading = sampler?.sample() {
            sample.pCoreMHz = reading.pCoreMHz
            sample.pCoreCeilingMHz = reading.pCoreCeilingMHz
            sample.eCoreMHz = reading.eCoreMHz
        }
        sample.thermalPressureRaw = ThermalPressure(
            processInfoState: ProcessInfo.processInfo.thermalState).rawValue

        let memory = MemoryReader.read()
        let state: SystemState? = callHelper { proxy, done in
            proxy.readSystemState { data in
                done(data.flatMap { try? JSONDecoder().decode(SystemState.self, from: $0) })
            }
        }
        let processes: [ProcessSnapshot.Entry] = callHelper(timeout: 30) { proxy, done in
            proxy.processSnapshot { data in
                done((data.flatMap {
                    try? JSONDecoder().decode(ProcessSnapshot.self, from: $0)
                })?.entries ?? [])
            }
        } ?? []

        let foreground = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))

        let findings = Diagnosis.analyze(
            sample: sample, memory: memory, state: state,
            processes: processes, foregroundPIDs: foreground)

        print("")
        for finding in findings {
            print(finding.severity.marker + finding.title.uppercased())
            if !finding.measured.isEmpty { print("      \(finding.measured)") }
            print("      → \(wrap(finding.advice))")
            if let basis = finding.basis {
                print("      base: \(wrap(basis))")
            }
            print("")
        }
        if processes.isEmpty {
            print("nota: senza helper non si vedono i processi di altri utenti,")
            print("      quindi la contesa e WindowServer restano invisibili.")
        }
    }

    /// Manda a capo a 68 colonne allineando le righe successive.
    private static func wrap(_ text: String, width: Int = 68) -> String {
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
        return lines.joined(separator: "\n            ")
    }

    /// Riporta il sistema alla baseline e rimuove ogni registrazione.
    ///
    /// L'ordine conta: prima si fa ripristinare all'helper le impostazioni,
    /// poi lo si deregistra. Al contrario non resterebbe nessuno a
    /// riaccendere Spotlight, e l'utente si troverebbe l'indicizzazione in
    /// pausa senza piu' alcuna interfaccia per rimediare.
    private static func uninstall() {
        let outcome: String? = callHelper { proxy, done in
            proxy.restoreAndCleanUp { done($0 ?? "") }
        }
        switch outcome {
        case .none:
            print(L("helper unreachable: nothing to restore"))
        case .some(let message) where !message.isEmpty:
            FileHandle.standardError.write(
                Data("ripristino incompleto: \(message)\n".utf8))
        default:
            print(L("settings restored"))
        }

        AppNapControl.setDisabled(false)

        // La registrazione via SMAppService, se c'e', va tolta da qui: e'
        // legata all'identita' di questo bundle e nessun comando esterno puo'
        // rimuoverla al posto suo.
        let daemon = SMAppService.daemon(plistName: WattIdentifiers.helperPlistName)
        if daemon.status != .notRegistered {
            do {
                try daemon.unregister()
                print(L("SMAppService registration removed"))
            } catch {
                FileHandle.standardError.write(Data(
                    "SMAppService non deregistrato: \(error.localizedDescription)\n".utf8))
            }
        }

        if FileManager.default.fileExists(atPath: WattIdentifiers.systemDaemonPlistPath) {
            print(L("the helper is registered in launchd; to remove it:"))
            print("  sudo ./scripts/uninstall-helper.sh")
        }
    }

    /// Applica un profilo, esegue un comando, ripristina il profilo
    /// precedente. Il ripristino avviene anche se il comando fallisce o viene
    /// interrotto: un profilo lasciato acceso da uno script che e' morto a
    /// meta' e' esattamente il tipo di residuo che questa app deve evitare.
    private static func runWrapped(_ arguments: [String]) {
        guard let name = arguments.first,
              let profile = PowerProfile(rawValue: name),
              let separator = arguments.firstIndex(of: "--"),
              arguments.count > separator + 1 else {
            fail("Uso: Watt --run <profilo> -- <comando ...>")
        }
        let command = Array(arguments[(separator + 1)...])
        let previous = Preferences.selectedProfile

        let restore = {
            _ = callHelper(timeout: 90) { proxy, done in
                proxy.applyProfile(previous.rawValue) { done($0) }
            } as String?
            AppNapControl.setDisabled(previous.plan.disableAppNap)
        }
        // Ctrl-C raggiunge l'intero gruppo di processi, quindi il figlio la
        // riceve da se' e questo processo puo' limitarsi ad aspettarne la
        // fine e ripristinare per la via normale.
        //
        // Il gestore precedente chiamava `exit()` dal contesto di segnale:
        // `exit()` esegue gli handler registrati con `atexit`, che qui
        // significa XPC e Foundation, e nessuna delle due e'
        // async-signal-safe. Ignorare il segnale e lasciar terminare il
        // figlio ottiene lo stesso risultato senza il rischio.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        apply(profile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        do {
            try process.run()
        } catch {
            restore()
            fail("impossibile eseguire \(command.joined(separator: " ")): "
               + error.localizedDescription)
        }
        process.waitUntilExit()
        restore()
        exit(process.terminationStatus)
    }

    /// Confronta la frequenza letta da IOReport con quella di
    /// `powermetrics`, sulla stessa finestra temporale.
    ///
    /// Le due misure non possono coincidere al megahertz: powermetrics apre
    /// una finestra di 500 ms, quella di IOReport la contiene ed e' un po'
    /// piu' larga, e la frequenza di un cluster cambia molte volte dentro
    /// quell'intervallo. Quello che il confronto deve escludere e' l'errore
    /// *sistematico*: uno scarto sempre dello stesso segno, o della misura
    /// di un intero gradino DVFS, non e' rumore di finestra.
    private static func verifyFrequency(rounds: Int) {
        guard let sampler = IOReportSampler() else {
            fail("IOReport non disponibile")
        }
        print("confronto IOReport / powermetrics, \(rounds) coppie\n")
        print("       IOReport     powermetrics      scarto    riposo")

        // Le due misure si confrontano **solo quando il cluster e' saturo**.
        //
        // A cluster parzialmente fermo i due numeri divergono per
        // definizione, non per errore: IOReport qui calcola la frequenza
        // media *mentre i core lavoravano* — gli stati di riposo sono
        // esclusi dalla media — mentre `freq_hz` di powermetrics e' una
        // media su tutto l'intervallo. Con il cluster P saturo le due
        // coincidono alla cifra (3204 contro 3204, scarto nullo); con il
        // cluster fermo al 95% IOReport dice 1,2 GHz e powermetrics 0,7,
        // e hanno ragione entrambe perche' stanno rispondendo a due domande
        // diverse.
        //
        // Watt mostra la prima: "a che velocita' gira quando lavora" e'
        // l'unica delle due in cui una limitazione termica si vede, perche'
        // l'altra scende anche solo perche' non c'e' niente da fare.
        // Per questo il verdetto si calcola sui soli campioni in cui il
        // riposo e' sotto il 10% **da entrambe le parti**: gli altri si
        // stampano — sono comunque informazione — ma non contano.
        //
        // Chiedere il riposo a tutt'e due le fonti e non solo a IOReport
        // serve contro il disallineamento delle finestre: powermetrics
        // misura per mezzo secondo dentro l'intervallo, piu' lungo, di
        // IOReport, e se in quel mezzo secondo il carico e' finito le due
        // guardano due macchine diverse. Con il solo riposo di IOReport
        // quel campione entrava nel conto e produceva scarti di centinaia
        // di megahertz che sembravano un errore di calcolo.
        var deltas: [Double] = []
        var discarded = 0

        for _ in 0..<max(1, rounds) {
            // Apre la finestra di IOReport: questo campione viene scartato,
            // conta solo come istante d'inizio.
            _ = sampler.sample()

            let sample: PowerSample? = callHelper(timeout: 30) { proxy, done in
                proxy.sampleMetrics { data in
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    done(data.flatMap { try? decoder.decode(PowerSample.self, from: $0) })
                }
            }
            let reading = sampler.sample()

            func row(_ tag: String, _ mine: Double?, _ theirs: Double?,
                     _ idle: Double?, _ theirIdle: Double? = nil) -> Bool {
                guard let mine else { return false }
                guard let theirs else {
                    print(String(format: "  %@  %7.0f MHz          n/d           -",
                                 tag, mine))
                    return false
                }
                let busy = (idle.map { $0 < 0.10 } ?? false)
                    && (theirIdle.map { $0 < 0.10 } ?? true)
                print(String(format: "  %@  %7.0f MHz     %7.0f MHz   %+6.0f MHz   %4.0f%%%@",
                             tag, mine, theirs, mine - theirs,
                             (idle ?? 0) * 100, busy ? "" : "  (scartato)"))
                return busy
            }

            if row("P", reading.pCoreMHz, sample?.pCoreMHz,
                   reading.pCoreIdleFraction, sample?.pCoreIdleRatio),
               let mine = reading.pCoreMHz, let theirs = sample?.pCoreMHz {
                deltas.append(mine - theirs)
            } else if sample?.pCoreMHz != nil {
                discarded += 1
            }
            _ = row("E", reading.eCoreMHz, sample?.eCoreMHz,
                    reading.eCoreIdleFraction)
        }

        guard !deltas.isEmpty else {
            print("\nnessuna coppia confrontabile.")
            print(discarded > 0
                ? "  in tutti i \(discarded) campioni il cluster P non era carico "
                + "abbastanza\n  perche' le due misure siano la stessa grandezza. "
                + "Mettilo sotto carico:\n\n    Watt --load 8 60 &\n    Watt "
                + "--verify-freq 5\n"
                : "  helper irraggiungibile?")
            return
        }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let worst = deltas.map(abs).max() ?? 0
        let sameSign = deltas.allSatisfy { $0 > 0 } || deltas.allSatisfy { $0 < 0 }
        print(String(format: "\n%d campioni a cluster saturo, %d scartati",
                     deltas.count, discarded))
        print(String(format: "scarto medio %+.0f MHz, massimo %.0f MHz", mean, worst))
        // Un errore che cambia segno e' rumore di finestra; uno che non lo
        // cambia mai e' un errore di calcolo, ed e' l'unico che va corretto.
        print(sameSign && abs(mean) > 150
            ? "  ⚠︎  sempre lo stesso segno: scarto sistematico, non rumore"
            : "  ✓  segno alternato o scarto piccolo: coerente col rumore di finestra")
    }

    /// Mostra come si comporta la lettura adattiva giro per giro.
    ///
    /// Serve a distinguere un fenomeno fisico da un artefatto di
    /// campionamento: se la media si muove insieme al *numero di sensori
    /// letti*, non e' il Mac che sta scaldando a intermittenza.
    private static func watchTemperatures(seconds: Int) {
        guard let sensors = ThermalSensors() else {
            fail(L("Thermal sensors are not readable on this system."))
        }
        // La colonna "full" e' la chiave di lettura di tutta la tabella: se
        // un salto della media coincide con una scansione completa, quel
        // salto e' il cambio di popolazione, non il Mac che scalda.
        print("giro  letti  full   max    media(letti)  media(die)")
        for tick in 0..<max(1, seconds) {
            let summary = sensors.readAdaptive()
            let all = summary.all.map(\.celsius)
            let mean = all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
            print(String(format: "%4d  %5d  ", tick, all.count)
                + (sensors.lastTickWasFullScan ? "si  " : "-   ")
                + String(format: "%5.1f  %8.1f  %11.1f",
                         summary.socCelsius ?? 0, mean,
                         summary.socAverageCelsius ?? 0))
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Confronto appaiato fra la pressione termica letta dal kernel e quella
    /// riportata da `powermetrics`.
    ///
    /// E' la prova che rende lecito smettere di pagare mezzo secondo di
    /// powermetrics per un dato che il kernel pubblica gratis. Le due letture
    /// vanno prese vicine: `powermetrics` misura su una finestra di mezzo
    /// secondo, quindi il livello del kernel si campiona **prima e dopo** la
    /// chiamata e si accetta l'accordo se coincide con almeno uno dei due —
    /// un cambio di livello proprio dentro la finestra non e' un disaccordo
    /// fra le fonti, e' un cambio di stato del Mac.
    private static func verifyPressure(rounds: Int) {
        let monitor = ThermalPressureMonitor()
        guard monitor.level != nil else {
            fail("Il kernel non pubblica com.apple.system.thermalpressurelevel "
               + "su questo sistema.")
        }
        print("confronto pressione termica: kernel contro powermetrics\n")
        print("giro   kernel(prima)  powermetrics   kernel(dopo)   esito")
        func pad(_ text: String?) -> String {
            (text ?? "?").padding(toLength: 15, withPad: " ", startingAt: 0)
        }

        var agreed = 0
        var compared = 0
        for round in 0..<max(1, rounds) {
            let before = monitor.level
            let sample: PowerSample? = callHelper(timeout: 30) { proxy, done in
                proxy.sampleMetrics { data in
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    done(data.flatMap { try? decoder.decode(PowerSample.self, from: $0) })
                }
            }
            let after = monitor.level
            guard let raw = sample?.thermalPressureRaw else {
                print(String(format: "%4d   ", round)
                    + pad(before?.rawValue) + pad("n/d") + pad(after?.rawValue)
                    + "helper assente")
                continue
            }
            let theirs = ThermalPressure(raw: raw)
            compared += 1
            let ok = theirs == before || theirs == after
            if ok { agreed += 1 }
            print(String(format: "%4d   ", round)
                + pad(before?.rawValue) + pad(raw) + pad(after?.rawValue)
                + (ok ? "=" : "DIVERSO"))
        }

        guard compared > 0 else {
            print("\nnessuna coppia valida: helper irraggiungibile?")
            return
        }
        print(String(format: "\n%d coppie su %d in accordo", agreed, compared))
        print(agreed == compared
            ? "  ✓  le due fonti coincidono: il kernel puo' sostituire powermetrics"
            : "  ⚠︎  disaccordo: la pressione va continuata a leggere da powermetrics")
    }

    /// Carico sintetico a QoS `userInteractive`, per misurare il throttling.
    ///
    /// La QoS non e' un dettaglio: un ciclo di shell eredita la classe
    /// `background`, e macOS confina i thread di quella classe sugli E-core.
    /// Otto cicli `while :; do :; done` fanno sudare gli E-core e lasciano il
    /// cluster P a 1188 MHz — la prova sembra girare e non misura niente.
    /// Con `userInteractive` lo scheduler li mette sui P-core e la curva di
    /// throttling e' quella vera.
    private static func generateLoad(threads: Int, seconds: Double) {
        let count = threads > 0 ? threads : ProcessInfo.processInfo.activeProcessorCount
        let deadline = Date().addingTimeInterval(max(1, seconds))
        print(String(format: "carico su %d thread a QoS userInteractive per %.0f s",
                     count, max(1, seconds)))
        print("(ctrl-C per fermarlo prima)")

        let group = DispatchGroup()
        for _ in 0..<count {
            DispatchQueue.global(qos: .userInteractive).async(group: group) {
                // Catena di dipendenze in virgola mobile: nessuna scrittura
                // in memoria, quindi si misura il clock del core e non la
                // banda verso la RAM.
                var accumulator = 1.0000001
                while Date() < deadline {
                    for _ in 0..<200_000 {
                        accumulator = accumulator * 1.0000001 + 1e-9
                    }
                    if accumulator > 1e300 { accumulator = 1.0000001 }
                }
                // Impedisce all'ottimizzatore di cancellare tutto il ciclo:
                // senza, il carico si riduce a un `return` e la prova
                // misurerebbe una macchina ferma.
                if accumulator == .infinity { print("") }
            }
        }
        group.wait()
        print("finito")
    }

    // MARK: - Client XPC sincrono

    /// Attende la risposta dell'helper con un semaforo: in modalita' CLI non
    /// c'e' un run loop su cui appoggiare una callback asincrona.
    /// - Parameter timeout: applicare un profilo comporta `purge` e
    ///   `taskpolicy` su tutti i daemon vivi, e una decina di secondi e'
    ///   normale. Letture e ripristino no: usare per tutti l'attesa piu'
    ///   lunga significava restare bloccati un minuto e mezzo davanti a un
    ///   helper semplicemente assente.
    private static func callHelper<T>(
        timeout: TimeInterval = 15,
        _ body: (WattHelperProtocol, @escaping (T?) -> Void) -> Void
    ) -> T? {
        let connection = NSXPCConnection(
            machServiceName: WattIdentifiers.helperMachService,
            options: .privileged)
        connection.remoteObjectInterface = makeWattHelperInterface()
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        // L'assenza dell'helper non e' un errore da stampare: le letture che
        // non lo richiedono funzionano lo stesso, e chi ne ha bisogno lo
        // segnala da se' con un messaggio che dice anche come installarlo.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            box.set(nil)
            semaphore.signal()
        }) as? WattHelperProtocol else { return nil }

        body(proxy) { value in
            box.set(value)
            semaphore.signal()
        }

        // L'attesa e' quella che il chiamante ha chiesto.
        //
        // Il parametro c'era gia', con tanto di spiegazione del perche'
        // servisse, e non veniva usato: si aspettavano novanta secondi per
        // qualunque chiamata, letture comprese. Un parametro documentato e
        // ignorato e' peggio di un parametro assente — chi legge il codice
        // crede che il comportamento sia quello scritto.
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return box.value
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

/// Trasporta il risultato dal thread di reply XPC a quello in attesa.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T?) { lock.lock(); stored = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Costo di ciascuna lettura periodica, in millisecondi.
private func benchmark() {
    func time(_ label: String, iterations: Int = 20, _ body: () -> Void) {
        body()  // giro a vuoto: la prima chiamata paga la cache fredda
        let start = Date()
        for _ in 0..<iterations { body() }
        let each = Date().timeIntervalSince(start) / Double(iterations) * 1000
        // `%-28@` non allinea: la larghezza minima vale per le stringhe C,
        // non per gli oggetti, e String(format:) la ignora in silenzio. Le
        // colonne uscivano tutte a filo e la tabella era illeggibile.
        print("   " + label.padding(toLength: 26, withPad: " ", startingAt: 0)
            + String(format: "%7.2f ms   %5.2f%% a 1 Hz", each, each / 10))
    }

    print("costo di un giro di campionamento\n")
    if let sensors = ThermalSensors() {
        let all = sensors.read()
        print("   \(all.all.count) sensori leggibili\n")
        time("sensori: tutti") { _ = sensors.read() }
        time("sensori: essenziali") { _ = sensors.readEssential() }
        time("sensori: solo die") { _ = sensors.readBar() }
        time("sensori: adattivo") { _ = sensors.readAdaptive() }
    }
    if let sampler = IOReportSampler() {
        time("frequenze (IOReport)") { _ = sampler.sample() }
    }
    time("memoria") { _ = MemoryReader.read() }
    // La pressione termica: e' questa riga a giustificare l'aver smesso di
    // chiamare powermetrics per averla. Il confronto e' con ~500 ms.
    let pressure = ThermalPressureMonitor()
    time("pressione (kernel)") { _ = pressure.level }
    time("batteria (registro IO)") { _ = BatteryReader.read() }
    print("\nla percentuale e' il costo continuo se la lettura")
    print("viene ripetuta una volta al secondo.")

    // Il risparmio vale solo se il numero mostrato resta quello giusto:
    // qui si confronta il massimo adattivo con quello letto per intero,
    // sugli stessi istanti.
    if let sensors = ThermalSensors() {
        print("\nfedelta' del campionamento adattivo (30 giri)\n")
        var worst = 0.0
        var sum = 0.0
        for _ in 0..<30 {
            let fast = sensors.readAdaptive().socCelsius ?? 0
            let full = sensors.read().socCelsius ?? 0
            let error = abs(full - fast)
            worst = max(worst, error)
            sum += error
            Thread.sleep(forTimeInterval: 0.1)
        }
        print(String(format: "   scarto medio   %.2f °C", sum / 30))
        print(String(format: "   scarto massimo %.2f °C", worst))

        // Controllo: due letture complete di fila. Lo scarto che resta qui e'
        // il rumore del sensore, non l'errore del metodo adattivo.
        var noise = 0.0
        for _ in 0..<30 {
            let a = sensors.read().socCelsius ?? 0
            let b = sensors.read().socCelsius ?? 0
            noise += abs(a - b)
            Thread.sleep(forTimeInterval: 0.1)
        }
        print(String(format: "   di cui rumore  %.2f °C  (due letture complete di fila)",
                     noise / 30))
    }
}
