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
            case .frequency:   return L("P-core frequency")
            case .socMax:      return L("Peak temperature (hottest die sensor)")
            case .socAverage:  return L("Average temperature (all die sensors)")
            case .battery:     return L("Battery temperature")
            case .storage:     return L("SSD temperature")
            case .freqAndTemp: return L("Frequency and peak temperature")
            }
        }
    }

    /// Cosa mostrare quando nessuno ha ancora scelto.
    ///
    /// Frequenza piu' **picco**, mai la media. Il picco e' il numero che
    /// decide quando il sistema comincia a limitare, e la media dei sedici
    /// sensori del die sta sempre qualche grado sotto: mostrarla in barra
    /// dei menu significa dire che il Mac e' piu' freddo di quanto sia nel
    /// punto che conta. La media resta disponibile, ma va scelta.
    static let defaultBarDisplay = BarDisplay.freqAndTemp

    static var barDisplay: BarDisplay {
        get {
            let stored = UserDefaults.standard.string(forKey: "barDisplay") ?? ""
            if let known = BarDisplay(rawValue: stored) { return known }
            // Valori scritti da versioni precedenti, quando i casi erano
            // `frequency`, `temperature` e `both`. Senza questa traduzione un
            // rinominare interno cancella in silenzio una scelta dell'utente,
            // che se la ritrova cambiata e non ha modo di capire perche'.
            switch stored {
            case "temperature": return .socMax
            case "both":        return defaultBarDisplay
            default:            return defaultBarDisplay
            }
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barDisplay") }
    }

    /// Cadenza di aggiornamento.
    ///
    /// Le etichette dicevano un costo per ciascuna scelta — «1 secondo
    /// (~1,7% di un core)» e a scendere — ricavato dal tempo di lettura dei
    /// sensori. Misurando il processo invece che il singolo pezzo, quei
    /// numeri sono risultati sbagliati, e non di poco: su M2 Air, a menu
    /// chiuso,
    ///
    ///     cadenza 2 s, frequenza + picco in barra     1,9% di un core
    ///     cadenza 2 s, solo picco in barra            1,2%
    ///     cadenza 10 s, testo quasi fermo             0,4%
    ///
    /// Il campionamento vero e proprio è quello 0,4%. Tutto il resto è
    /// AppKit che ridisegna l'elemento in barra dei menu ogni volta che il
    /// testo cambia — nel profilo del processo è
    /// `NSStatusItem _updateReplicants`, due terzi del totale. Da cui:
    /// rallentare la cadenza aiuta molto meno di quanto sembri, e scegliere
    /// una grandezza che cambia di rado aiuta molto di più.
    ///
    /// Le etichette quindi non promettono più una percentuale per opzione:
    /// promettere un numero misurato male è peggio che non prometterne.
    /// Il costo si misura con `Watt --bench` e col profilo del processo.
    enum Cadence: Double, CaseIterable {
        case realtime = 1
        case fast = 2
        case normal = 5
        case relaxed = 10

        var label: String {
            switch self {
            case .realtime: return L("1 second")
            case .fast:     return L("2 seconds")
            case .normal:   return L("5 seconds")
            case .relaxed:  return L("10 seconds")
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
