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

/// Lingua in cui deve rispondere il modello di Apple Intelligence.
///
/// Il nome della lingua va scritto in inglese perché è la lingua in cui sono
/// scritte le istruzioni, e un modello piccolo segue meglio un'istruzione che
/// non cambia lingua a metà. Si ricava da quella scelta per l'interfaccia, non
/// dalla lingua di sistema: chi legge Watt in italiano vuole la spiegazione in
/// italiano, quale che sia la lingua del Mac.
public enum Localization {
    public static var modelLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: "en")
            .localizedString(forLanguageCode: String(code.prefix(2)))
            ?? "English"
    }
}
