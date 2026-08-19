import Foundation

/// Identificatori condivisi fra app e helper.
///
/// `teamIdentifier` viene sovrascritto a build time da `scripts/build.sh`
/// leggendo l'identita' di firma effettiva, cosi' il requisito di codesign
/// non resta inchiodato al Mac di sviluppo.
public enum WattIdentifiers {
    public static let appBundleID = "dev.andreapiani.watt"
    public static let helperMachService = "dev.andreapiani.watt.helper"
    public static let helperPlistName = "dev.andreapiani.watt.helper.plist"

    /// Team ID Apple Developer usato per firmare app e helper.
    public static let teamIdentifier = WattBuildConfig.teamIdentifier

    /// Requisito di codesign che l'helper impone al client XPC.
    ///
    /// Senza questo, qualunque processo dell'utente potrebbe pilotare un
    /// demone root. Il controllo e' la parte piu' importante dell'helper.
    public static var clientRequirement: String {
        """
        identifier "\(appBundleID)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
    }

    /// Percorso dello snapshot delle impostazioni originali del sistema.
    public static let baselinePath = "/Library/Application Support/Watt/baseline.json"

    /// Plist scritto da `scripts/install-helper.sh` quando l'helper viene
    /// registrato direttamente in launchd invece che via SMAppService.
    public static let systemDaemonPlistPath =
        "/Library/LaunchDaemons/dev.andreapiani.watt.helper.plist"
}
