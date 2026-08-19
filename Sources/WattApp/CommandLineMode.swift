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
            print("apertura all'avvio: "
                + (Preferences.launchAtLogin ? "attiva" : "disattivata"))
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
            else { fail("Helper non raggiungibile.") }
            if suspending {
                print(report.suspended.isEmpty
                    ? "nessun servizio differibile in esecuzione"
                    : "congelati: " + report.suspended.joined(separator: ", "))
                if let expiry = report.expiresAt {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    print("si riattivano da soli alle \(formatter.string(from: expiry))")
                }
            } else {
                print(report.resumed.isEmpty
                    ? "nessun servizio era congelato"
                    : "riattivati: " + report.resumed.joined(separator: ", "))
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
            else { fail("Helper non raggiungibile.") }
            print(report.summary)
            for entry in report.throttled.prefix(20) {
                print(String(format: "   %-24@ %5.1f%%  %6.0f MB",
                             entry.name as NSString, entry.cpuPercent, entry.memoryMB))
            }
            return true

        case "--unthrottle":
            _ = callHelper(timeout: 60) { proxy, done in
                proxy.restoreThrottled { done($0 ?? "") }
            } as String?
            print("priorità normale ripristinata")
            return true

        case "--temps":
            guard let summary = ThermalSensors()?.read(), !summary.all.isEmpty else {
                fail("Sensori termici non leggibili su questo sistema.")
            }
            print(String(format: "SoC      : %@",
                         ThermalSensors.Summary.format(summary.socCelsius)))
            print(String(format: "batteria : %@",
                         ThermalSensors.Summary.format(summary.batteryCelsius)))
            print(String(format: "SSD      : %@",
                         ThermalSensors.Summary.format(summary.storageCelsius)))
            print("\n\(summary.all.count) sensori:")
            for reading in summary.all {
                print(String(format: "   %-24@ %6.1f °C",
                             reading.name as NSString, reading.celsius))
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
            print("memoria disponibile: \(after?.availableText ?? "n/d")")
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
          Watt --temps             tutte le temperature dei sensori
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
            print("profilo: \(profile.title)")
            exit(1)
        }
        print("profilo: \(profile.title)")

        // La sospensione inibita richiede un processo vivo che tenga
        // l'assertion: da riga di comando non c'e' nessuno a tenerla, e
        // dirlo e' meglio che lasciar credere il contrario.
        if profile.plan.preventIdleSleep {
            print("nota: la sospensione resta inibita solo con l'app in esecuzione")
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

        print("profilo salvato : \(Preferences.selectedProfile.title)")

        if let reading, let mhz = reading.pCoreMHz {
            let ceiling = reading.pCoreCeilingMHz ?? 0
            print(ceiling > 0
                ? String(format: "P-core          : %.2f di %.2f GHz", mhz / 1000, ceiling / 1000)
                : String(format: "P-core          : %.2f GHz", mhz / 1000))
        }
        if let mhz = reading?.eCoreMHz {
            print(String(format: "E-core          : %.2f GHz", mhz / 1000))
        }
        print("termico         : \(pressure.label)"
            + (pressure.isThrottling ? "  <- prestazioni limitate" : ""))
        if let temps = ThermalSensors()?.read() {
            print("temperatura SoC : \(ThermalSensors.Summary.format(temps.socCelsius))")
            print("batteria / SSD  : "
                + ThermalSensors.Summary.format(temps.batteryCelsius) + " / "
                + ThermalSensors.Summary.format(temps.storageCelsius))
        }
        if let watts = sample?.packageWattsText {
            print("pacchetto       : \(watts)")
        }
        if let state {
            print("low power mode  : \(state.lowPowerMode ? "attivo" : "spento")")
            print("power nap       : \(state.powerNap ? "attivo" : "spento")")
            print("spotlight       : \(state.spotlightIndexing ? "attivo" : "in pausa")")
            print("time machine    : \(state.timeMachineAutomatic ? "automatico" : "in pausa")")
            print("app nap         : \(AppNapControl.isDisabled ? "disattivato" : "attivo")")
            print("helper          : \(state.helperVersion)")
        }
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
            print("helper non raggiungibile: niente da ripristinare")
        case .some(let message) where !message.isEmpty:
            FileHandle.standardError.write(
                Data("ripristino incompleto: \(message)\n".utf8))
        default:
            print("impostazioni ripristinate")
        }

        AppNapControl.setDisabled(false)

        // La registrazione via SMAppService, se c'e', va tolta da qui: e'
        // legata all'identita' di questo bundle e nessun comando esterno puo'
        // rimuoverla al posto suo.
        let daemon = SMAppService.daemon(plistName: WattIdentifiers.helperPlistName)
        if daemon.status != .notRegistered {
            do {
                try daemon.unregister()
                print("registrazione SMAppService rimossa")
            } catch {
                FileHandle.standardError.write(Data(
                    "SMAppService non deregistrato: \(error.localizedDescription)\n".utf8))
            }
        }

        if FileManager.default.fileExists(atPath: WattIdentifiers.systemDaemonPlistPath) {
            print("l'helper e' registrato in launchd, per rimuoverlo:")
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

        // Applicare "Massimo" comporta purge piu
        // taskpolicy su tutti i daemon vivi: qualche secondo e' normale.
        if semaphore.wait(timeout: .now() + 90) == .timedOut { return nil }
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
