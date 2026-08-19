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

    /// Ripristina lo snapshot originale e rimuove lo stato persistente.
    /// Va chiamata prima di deregistrare l'helper, altrimenti il Mac resta
    /// con Spotlight in pausa e la sospensione disabilitata.
    func restoreAndCleanUp(reply: @escaping (String?) -> Void)
}

public enum WattHelperVersion {
    public static let current = "1.0.0"
}
