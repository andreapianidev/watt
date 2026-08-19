import Foundation

/// I quattro livelli esposti in menu bar.
///
/// Nota di onesta' tecnica: su Apple Silicon nessuno di questi livelli alza
/// la frequenza dei core. I P-core dell'M2 boostano gia' al massimo di
/// default, a batteria come in carica, e il DVFS non e' esposto ne' a
/// userspace ne' a kext. `Prestazioni` e `Massimo` agiscono togliendo
/// contesa (indicizzazione, backup, daemon in background) e impedendo che il
/// sistema addormenti o metta in nap l'app in primo piano. `Risparmio`
/// invece incide davvero sul clock, perche' Low Power Mode e' l'unica leva
/// prestazionale che il firmware espone su questo hardware.
public enum PowerProfile: String, Codable, CaseIterable, Sendable {
    case risparmio
    case automatico
    case prestazioni
    case massimo

    public var title: String {
        switch self {
        case .risparmio:   return "Risparmio"
        case .automatico:  return "Automatico"
        case .prestazioni: return "Prestazioni"
        case .massimo:     return "Massimo"
        }
    }

    public var symbolName: String {
        switch self {
        case .risparmio:   return "leaf.fill"
        case .automatico:  return "circle.lefthalf.filled"
        case .prestazioni: return "bolt.fill"
        case .massimo:     return "bolt.horizontal.fill"
        }
    }

    /// Descrizione mostrata nelle preferenze: dice esattamente cosa cambia.
    public var explanation: String {
        switch self {
        case .risparmio:
            return "Low Power Mode attivo, Power Nap spento, schermo e disco "
                 + "si spengono prima. Riduce il clock in modo reale."
        case .automatico:
            return "Ripristina esattamente le impostazioni di sistema "
                 + "registrate alla prima esecuzione. Nessuna modifica attiva."
        case .prestazioni:
            return "Low Power Mode spento, indicizzazione Spotlight e backup "
                 + "Time Machine in pausa, App Nap disattivato, sospensione "
                 + "inibita. Libera CPU e I/O, non alza il clock."
        case .massimo:
            return "Come Prestazioni, piu' i daemon di sistema noti confinati "
                 + "sugli E-core, che sotto pressione termica restano a piena "
                 + "velocita' mentre i P-core no. Il limite finale resta "
                 + "termico: l'Air non ha ventola."
        }
    }

    /// Configurazione applicata dall'helper.
    public var plan: ProfilePlan {
        switch self {
        case .risparmio:
            return ProfilePlan(lowPowerMode: true, powerNap: false,
                               pauseSpotlight: false, pauseTimeMachine: false,
                               disableAppNap: false, preventIdleSleep: false,
                               demoteBackgroundDaemons: false)
        case .automatico:
            return ProfilePlan(lowPowerMode: false, powerNap: nil,
                               pauseSpotlight: false, pauseTimeMachine: false,
                               disableAppNap: false, preventIdleSleep: false,
                               demoteBackgroundDaemons: false, restoreBaseline: true)
        case .prestazioni:
            return ProfilePlan(lowPowerMode: false, powerNap: false,
                               pauseSpotlight: true, pauseTimeMachine: true,
                               disableAppNap: true, preventIdleSleep: true,
                               demoteBackgroundDaemons: false)
        case .massimo:
            return ProfilePlan(lowPowerMode: false, powerNap: false,
                               pauseSpotlight: true, pauseTimeMachine: true,
                               disableAppNap: true, preventIdleSleep: true,
                               demoteBackgroundDaemons: true)
        }
    }
}

/// Insieme di modifiche che l'helper applica per un profilo.
/// Ogni campo `nil` significa "non toccare".
public struct ProfilePlan: Codable, Sendable {
    // --- applicate dall'helper privilegiato ---
    public var lowPowerMode: Bool?
    public var powerNap: Bool?
    public var pauseSpotlight: Bool
    public var pauseTimeMachine: Bool
    public var demoteBackgroundDaemons: Bool
    /// Se `true`, prima di tutto ripristina lo snapshot originale.
    public var restoreBaseline: Bool

    // --- applicate dall'app, senza privilegi ---

    /// App Nap vive nel dominio globale **dell'utente**: scriverlo dall'helper
    /// finirebbe nelle preferenze di root, dove non ha alcun effetto.
    public var disableAppNap: Bool

    /// Sospensione inibita con una `IOPMAssertion` invece di
    /// `pmset disablesleep`. L'assertion muore insieme al processo, mentre
    /// l'impostazione di pmset sopravvivrebbe a un crash lasciando il Mac
    /// perennemente sveglio senza che nulla lo segnali.
    public var preventIdleSleep: Bool

    public init(lowPowerMode: Bool? = nil, powerNap: Bool? = nil,
                pauseSpotlight: Bool = false, pauseTimeMachine: Bool = false,
                disableAppNap: Bool = false, preventIdleSleep: Bool = false,
                demoteBackgroundDaemons: Bool = false,
                restoreBaseline: Bool = false) {
        self.lowPowerMode = lowPowerMode
        self.powerNap = powerNap
        self.pauseSpotlight = pauseSpotlight
        self.pauseTimeMachine = pauseTimeMachine
        self.disableAppNap = disableAppNap
        self.preventIdleSleep = preventIdleSleep
        self.demoteBackgroundDaemons = demoteBackgroundDaemons
        self.restoreBaseline = restoreBaseline
    }
}

/// Daemon di sistema che `Massimo` confina sugli E-core con `taskpolicy -b`.
///
/// Lista deliberatamente conservativa: solo processi di indicizzazione,
/// backup e sincronizzazione, che sono rinviabili per definizione. Niente
/// `WindowServer`, `kernel_task`, `launchd`, `loginwindow` o audio: degradarli
/// si vede subito e non libera nulla di utile.
public enum BackgroundDaemons {
    public static let names = [
        "mds", "mds_stores", "mdworker_shared", "mdbulkimport",
        "backupd", "backupd-helper",
        "cloudd", "bird", "syncdefaultsd",
        "photoanalysisd", "photolibraryd", "mediaanalysisd",
        "suggestd", "corespotlightd", "knowledge-agent",
    ]
}
