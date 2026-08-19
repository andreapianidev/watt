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

    static var metricsInterval: TimeInterval { cadence.rawValue }

    /// Cosa mostrare accanto all'icona in barra dei menu.
    enum BarDisplay: String, CaseIterable {
        case frequency, socMax, socAverage, battery, storage, freqAndTemp

        var label: String {
            switch self {
            case .frequency:   return "Frequenza P-core"
            case .socMax:      return "Temperatura massima"
            case .socAverage:  return "Temperatura media"
            case .battery:     return "Temperatura batteria"
            case .storage:     return "Temperatura SSD"
            case .freqAndTemp: return "Frequenza e temperatura"
            }
        }
    }

    static var barDisplay: BarDisplay {
        get {
            BarDisplay(rawValue: UserDefaults.standard.string(forKey: "barDisplay") ?? "")
                ?? .socMax
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barDisplay") }
    }

    /// Cadenza di aggiornamento, con il costo di ciascuna scelta.
    ///
    /// Leggere i sedici sensori sul die costa circa 17 ms, quindi un
    /// aggiornamento al secondo occupa l'1,7% di un core in permanenza. È
    /// poco ma non è zero, e su un'app che resta accesa per giorni va detto
    /// invece che nascosto.
    enum Cadence: Double, CaseIterable {
        case realtime = 1
        case fast = 2
        case normal = 5
        case relaxed = 10

        var label: String {
            switch self {
            case .realtime: return "1 secondo (~1,7% di un core)"
            case .fast:     return "2 secondi (~0,9%)"
            case .normal:   return "5 secondi (~0,3%)"
            case .relaxed:  return "10 secondi (~0,2%)"
            }
        }
    }

    static var cadence: Cadence {
        get {
            Cadence(rawValue: UserDefaults.standard.double(forKey: intervalKey))
                ?? .fast
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: intervalKey) }
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
