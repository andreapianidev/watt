import Foundation

/// Valori iniettati a build time. `scripts/build.sh` riscrive questo file
/// prima di compilare; il default serve solo a far compilare il sorgente
/// appena clonato.
public enum WattBuildConfig {
    public static let teamIdentifier = "58A5S55HKD"
    /// Se `true` l'helper accetta qualunque client senza verificarne la firma.
    /// Solo per sviluppo locale con binari non firmati. MAI in distribuzione.
    public static let skipClientVerification = false
}
