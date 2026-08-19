import Foundation

/// Controlla App Nap tramite il dominio globale dell'utente.
///
/// `defaults write -g NSAppSleepDisabled` eseguito dall'helper finirebbe
/// nelle preferenze di **root**, dove non ha alcun effetto sulle app della
/// sessione grafica. Va scritto dal processo dell'utente, che e' questo.
enum AppNapControl {

    /// Proprieta' calcolata e non `static let`: `CFString` non e' `Sendable`
    /// e come stato globale mutabile non passerebbe il controllo di
    /// concorrenza di Swift 6.
    private static var key: CFString { "NSAppSleepDisabled" as CFString }

    static var isDisabled: Bool {
        let value = CFPreferencesCopyValue(
            key, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? Bool) ?? false
    }

    /// macOS legge `NSAppSleepDisabled` all'avvio di ciascuna app: il cambio
    /// vale per i processi lanciati **dopo**, non per quelli gia' in
    /// esecuzione. E' una limitazione del sistema, non un bug da aggirare;
    /// l'interfaccia lo dichiara invece di lasciar credere il contrario.
    static func setDisabled(_ disabled: Bool) {
        CFPreferencesSetValue(
            key, disabled ? kCFBooleanTrue : nil,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }
}
