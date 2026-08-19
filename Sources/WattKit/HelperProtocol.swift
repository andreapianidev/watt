import Foundation

/// Interfaccia XPC esposta dall'helper privilegiato.
///
/// Tutti i tipi scambiati sono `Data` con payload JSON: evita di dover
/// configurare `NSSecureCoding` su classi custom e mantiene il contratto
/// leggibile.
@objc public protocol WattHelperProtocol {
    /// Versione dell'helper installato, per rilevare un helper stantio dopo
    /// un aggiornamento dell'app.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Applica un profilo. `profileRaw` e' il `rawValue` di `PowerProfile`.
    /// La reply riporta `nil` in caso di successo, altrimenti la descrizione
    /// del primo errore incontrato.
    func applyProfile(_ profileRaw: String, reply: @escaping (String?) -> Void)

    /// Legge lo stato reale del sistema. Payload: `SystemState` in JSON.
    func readSystemState(reply: @escaping (Data?) -> Void)

    /// Un campione di `powermetrics`. Payload: `PowerSample` in JSON.
    func sampleMetrics(reply: @escaping (Data?) -> Void)

    /// Individua i processi in background che stanno consumando CPU e li
    /// confina sugli E-core.
    ///
    /// - Parameter protectedPIDs: PID delle applicazioni con interfaccia,
    ///   raccolti dall'app. L'helper non può distinguerle da solo — dal suo
    ///   punto di vista Xcode che compila e un daemon che indicizza sono
    ///   entrambi processi che consumano — e rallentare ciò con cui stai
    ///   lavorando sarebbe esattamente il contrario di quello che serve.
    ///
    /// Payload della risposta: `ThrottleReport` in JSON.
    func throttleHeavyBackground(protectedPIDs: [NSNumber],
                                 reply: @escaping (Data?) -> Void)

    /// Processi ordinati per consumo di CPU istantaneo.
    ///
    /// Passa dall'helper perche' `proc_pid_rusage` sui processi di altri
    /// utenti richiede privilegi: senza, `WindowServer` — che e' spesso il
    /// vero responsabile — resterebbe invisibile.
    ///
    /// Payload della risposta: `ProcessSnapshot` in JSON.
    func processSnapshot(reply: @escaping (Data?) -> Void)

    /// Congela con SIGSTOP i servizi di sistema differibili.
    ///
    /// Payload della risposta: `SuspensionReport` in JSON.
    func suspendServices(reply: @escaping (Data?) -> Void)

    /// Li riattiva con SIGCONT.
    func resumeServices(reply: @escaping (Data?) -> Void)

    /// Ripristina la priorità normale di tutto ciò che era stato rallentato.
    func restoreThrottled(reply: @escaping (String?) -> Void)

    /// Libera la memoria inattiva con `purge`.
    ///
    /// Misurato su M2 Air / macOS 27: circa 1 GB liberato in 1,3 secondi.
    /// Sfratta anche la cache dei file, quindi la prima lettura successiva
    /// torna al disco: utile *prima* di una build pesante, inutile durante.
    func purgeMemory(reply: @escaping (String?) -> Void)

    /// Ripristina lo snapshot originale e rimuove lo stato persistente.
    /// Va chiamata prima di deregistrare l'helper, altrimenti il Mac resta
    /// con Spotlight in pausa e la sospensione disabilitata.
    func restoreAndCleanUp(reply: @escaping (String?) -> Void)
}

/// Costruisce l'interfaccia XPC.
///
/// NSXPCConnection accetta di default solo un insieme ristretto di tipi: per
/// un argomento `[NSNumber]` le classi consentite vanno dichiarate
/// esplicitamente, altrimenti la chiamata viene rifiutata a runtime con un
/// errore che non nomina l'argomento colpevole.
public func makeWattHelperInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: WattHelperProtocol.self)
    let selector = #selector(WattHelperProtocol.throttleHeavyBackground(protectedPIDs:reply:))
    interface.setClasses(
        NSSet(array: [NSArray.self, NSNumber.self]) as! Set<AnyHashable>,
        for: selector, argumentIndex: 0, ofReply: false)
    return interface
}

public enum WattHelperVersion {
    public static let current = "1.0.0"
}
