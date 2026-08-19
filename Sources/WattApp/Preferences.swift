import Foundation
import ServiceManagement
import WattKit

/// Impostazioni dell'app.
enum Preferences {

    /// Notifica emessa quando il profilo viene cambiato da un altro processo.
    ///
    /// L'app in barra dei menu e le invocazioni da riga di comando sono
    /// processi distinti che condividono lo stesso dominio di preferenze. Chi
    /// resta in esecuzione tiene il proprio valore in memoria e non si accorge
    /// delle scritture altrui: senza questo avviso, `Watt --apply automatico`
    /// configurava il sistema ma il menu continuava a mostrare il profilo
    /// precedente, e alla prima riscrittura lo ripristinava pure.
    static let profileChangedNotification = "dev.andreapiani.watt.profileChanged"

    private static let profileKey = "selectedProfile"
    private static let intervalKey = "metricsIntervalSeconds"

    static var selectedProfile: PowerProfile {
        get {
            guard let raw = UserDefaults.standard.string(forKey: profileKey),
                  let profile = PowerProfile(rawValue: raw)
            else { return .automatico }
            return profile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: profileKey)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(profileChangedNotification),
                object: newValue.rawValue, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Rilegge dal disco, scartando il valore tenuto in memoria.
    static func reloadedProfile() -> PowerProfile {
        UserDefaults.standard.synchronize()
        guard let raw = UserDefaults.standard.string(forKey: profileKey),
              let profile = PowerProfile(rawValue: raw)
        else { return .automatico }
        return profile
    }

    /// Il valore era prudente quando ogni campione faceva girare
    /// `powermetrics` per mezzo secondo. Ora frequenze, temperature e
    /// memoria si leggono da IOReport, IOHID e Mach senza lanciare nulla, e
    /// costano microsecondi: tenere la barra dei menu ferma per quindici
    /// secondi non proteggeva piu' niente, rendeva solo il numero stantio.
    static var metricsInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return stored > 0 ? stored : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    /// Cosa mostrare accanto all'icona in barra dei menu.
    enum BarDisplay: String, CaseIterable {
        case frequency, temperature, both

        var label: String {
            switch self {
            case .frequency:   return "Frequenza"
            case .temperature: return "Temperatura"
            case .both:        return "Entrambe"
            }
        }
    }

    static var barDisplay: BarDisplay {
        get {
            BarDisplay(rawValue: UserDefaults.standard.string(forKey: "barDisplay") ?? "")
                ?? .frequency
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barDisplay") }
    }

    static var alertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alertsEnabled") }
    }

    static var alertThreshold: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "alertThreshold")
            return stored > 0 ? stored : 90
        }
        set { UserDefaults.standard.set(newValue, forKey: "alertThreshold") }
    }

    static var keepDisplayOn: Bool {
        get { UserDefaults.standard.bool(forKey: "keepDisplayOn") }
        set { UserDefaults.standard.set(newValue, forKey: "keepDisplayOn") }
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
