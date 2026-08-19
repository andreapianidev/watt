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
        case .risparmio:   return L("Low Power")
        case .automatico:  return L("Automatic")
        case .prestazioni: return L("High")
        case .massimo:     return L("Maximum")
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
            return L("Low Power Mode on, Power Nap off, display and disk sleep "
                   + "sooner. This one genuinely lowers the clock.")
        case .automatico:
            return L("Restores the exact system settings recorded on first "
                   + "run. Nothing is actively changed.")
        case .prestazioni:
            return L("Stops scheduled background work: Spotlight indexing "
                   + "and Time Machine paused, App Nap off, sleep prevented. "
                   + "Nothing already running is touched.")
        case .massimo:
            return L("Everything in High, and also acts on what is already "
                   + "running: known daemons confined to E-cores, deferrable "
                   + "services frozen, inactive memory freed. Takes about ten "
                   + "seconds longer to apply.")
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
                               demoteBackgroundDaemons: true, purgeMemory: true)
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
    /// Libera la memoria inattiva al momento dell'applicazione. Una tantum,
    /// non uno stato: non ha un inverso e non entra nella baseline.
    public var purgeMemory: Bool
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
                purgeMemory: Bool = false,
                restoreBaseline: Bool = false) {
        self.lowPowerMode = lowPowerMode
        self.powerNap = powerNap
        self.pauseSpotlight = pauseSpotlight
        self.pauseTimeMachine = pauseTimeMachine
        self.disableAppNap = disableAppNap
        self.preventIdleSleep = preventIdleSleep
        self.demoteBackgroundDaemons = demoteBackgroundDaemons
        self.purgeMemory = purgeMemory
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
        // Indicizzazione: durante una build macina DerivedData e node_modules,
        // cioe' esattamente le directory che stai riscrivendo.
        "mds", "mds_stores", "mdworker_shared", "mdbulkimport",
        "corespotlightd", "suggestd", "knowledge-agent",
        // Backup e sincronizzazione cloud.
        "backupd", "backupd-helper",
        "cloudd", "bird", "syncdefaultsd",
        // Analisi contenuti multimediali.
        "photoanalysisd", "photolibraryd", "mediaanalysisd",
        // Client di sincronizzazione di terze parti, se presenti.
        "Dropbox", "FileProvider", "GoogleDriveFS", "OneDrive",
        // Aggiornamenti e manutenzione differibili.
        "softwareupdated", "SoftwareUpdateNotificationManager",
        "AssetCacheLocatorService",
    ]
}
