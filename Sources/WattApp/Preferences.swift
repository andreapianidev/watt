import Foundation
import ServiceManagement
import WattKit

/// Impostazioni dell'app.
enum Preferences {

    private static let profileKey = "selectedProfile"
    private static let intervalKey = "metricsIntervalSeconds"

    static var selectedProfile: PowerProfile {
        get {
            guard let raw = UserDefaults.standard.string(forKey: profileKey),
                  let profile = PowerProfile(rawValue: raw)
            else { return .automatico }
            return profile
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: profileKey) }
    }

    /// Ogni campione fa girare `powermetrics` per mezzo secondo, che a sua
    /// volta consuma. Un intervallo troppo fitto renderebbe l'app parte del
    /// problema che dice di misurare: il default e' volutamente prudente.
    static var metricsInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return stored > 0 ? stored : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[Watt] apertura all'avvio non modificata: %@",
                      error.localizedDescription)
            }
        }
    }
}
