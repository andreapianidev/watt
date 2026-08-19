import Foundation

/// Traduzione di una stringa visibile all'utente.
///
/// La chiave è il testo inglese stesso, non un identificatore astratto. Così
/// il sorgente si legge senza saltare a una tabella, e una traduzione mancante
/// degrada in inglese invece che in `menu.profile.low.title`.
///
/// Il lookup passa da `Bundle.main`, che è il bundle dell'app anche quando la
/// chiamata parte da questo modulo: le `.lproj` stanno lì, non dentro il
/// package.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Variante con argomenti di formato.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

public extension String {
    /// Comodità per le stringhe letterali: `"Low Power".localized`.
    var localized: String { L(self) }
}
