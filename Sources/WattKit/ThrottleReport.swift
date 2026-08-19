import Foundation

/// Esito di un intervento di rallentamento mirato.
public struct ThrottleReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var pid: Int32
        public var cpuPercent: Double
        public var memoryMB: Double

        public init(name: String, pid: Int32, cpuPercent: Double, memoryMB: Double) {
            self.name = name
            self.pid = pid
            self.cpuPercent = cpuPercent
            self.memoryMB = memoryMB
        }
    }

    public var throttled: [Entry]
    public var skipped: [String]
    public var failure: String?

    public init(throttled: [Entry] = [], skipped: [String] = [],
                failure: String? = nil) {
        self.throttled = throttled
        self.skipped = skipped
        self.failure = failure
    }

    public var totalCPUFreed: Double { throttled.map(\.cpuPercent).reduce(0, +) }

    /// Riepilogo leggibile.
    ///
    /// A sistema scarico i daemon rinviabili vengono confinati lo stesso, ma
    /// non stanno consumando nulla: annunciare "0% di CPU liberata" sarebbe
    /// vero e inutile, e prometterne una qualsiasi sarebbe falso. Si dice
    /// cosa è stato fatto, e il guadagno solo quando c'è.
    public var summary: String {
        guard !throttled.isEmpty else { return "nessun processo da rallentare" }
        let count = throttled.count
        if totalCPUFreed < 1 {
            return "\(count) processi differibili confinati sugli E-core "
                 + "(al momento non stavano consumando)"
        }
        return String(format: "%d processi rallentati, ~%.0f%% di CPU liberata",
                      count, totalCPUFreed)
    }
}

/// Processi che non vanno mai rallentati, per nessuna ragione.
///
/// Degradarli non libera nulla di utile e si vede immediatamente: audio che
/// gracchia, interfaccia a scatti, input in ritardo. La lista è volutamente
/// più larga del necessario — il costo di un falso positivo qui è un Mac che
/// sembra rotto, quello di un falso negativo è qualche punto di CPU in meno.
public enum ProtectedProcesses {
    public static let names: Set<String> = [
        // Nucleo del sistema e sessione grafica.
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "SystemUIServer", "Dock", "Finder", "ControlCenter", "NotificationCenter",
        "runningboardd", "logd", "opendirectoryd", "securityd",
        // Audio e input: qualunque degrado qui è udibile o percepibile.
        "coreaudiod", "audiomxd", "AudioComponentRegistrar",
        "hidd", "eventkitd", "TouchBarServer",
        // Rete e sicurezza.
        "mDNSResponder", "networkd", "nesessionmanager", "trustd",
        // Watt stesso: rallentare il proprio helper è un modo curioso di
        // rendere lente le misure che servono a decidere cosa rallentare.
        "Watt", "watt-helper", "dev.andreapiani.watt.helper",
        // Shell e sessioni interattive. Non sono applicazioni con interfaccia,
        // quindi la protezione delle app visibili non le copre, ma dietro
        // ciascuna c'è qualcuno che sta aspettando una risposta: rallentarle
        // è il primo effetto che si nota e l'ultimo di cui si sospetta.
        "zsh", "bash", "sh", "fish", "csh", "tcsh", "dash",
        "login", "tmux", "screen", "ssh", "sshd", "sudo", "su",
    ]

    /// Soglia di CPU sotto la quale un processo non vale l'intervento.
    /// Rallentare qualcosa che usa l'1% non libera niente di misurabile e
    /// allunga soltanto l'elenco di ciò che hai modificato.
    public static let minimumCPUPercent: Double = 3
}


/// Servizi che possono essere **congelati** con SIGSTOP, non solo declassati.
///
/// Un processo fermato con SIGSTOP consuma esattamente zero: non viene mai
/// schedulato finché non riceve SIGCONT. È molto più efficace di
/// `taskpolicy -b`, che si limita a spostarlo in coda, ed è altrettanto
/// reversibile — ma solo se si sceglie bene cosa fermare.
///
/// La lista contiene esclusivamente lavoro **differibile e senza dipendenze
/// dall'interfaccia**: indicizzazione, analisi foto, backup, aggiornamenti.
/// Se uno di questi resta fermo dieci minuti non se ne accorge nessuno, e
/// riprende esattamente da dove era rimasto.
///
/// Sono deliberatamente **esclusi** i servizi iCloud (`cloudd`, `bird`,
/// `FileProvider`): il Finder può bloccarsi in attesa di una risposta da
/// loro, e un Finder congelato è indistinguibile da un Mac rotto.
public enum SuspendableServices {
    public static let names: [String] = [
        // Indicizzazione Spotlight.
        "mds", "mds_stores", "mdworker_shared", "mdbulkimport",
        "corespotlightd", "suggestd", "knowledge-agent",
        // Analisi della libreria foto.
        "photoanalysisd", "photolibraryd", "mediaanalysisd",
        // Backup.
        "backupd", "backupd-helper",
        // Aggiornamenti e cache differibili.
        "softwareupdated", "AssetCacheLocatorService",
    ]

    /// Oltre questo tempo i servizi vengono riattivati da soli.
    ///
    /// È la rete di sicurezza contro il caso peggiore: Watt che muore mentre
    /// tiene fermi dei servizi di sistema. Senza, resterebbero congelati fino
    /// al riavvio, e nessuno collegherebbe mai Spotlight che non indicizza più
    /// a un'app chiusa due giorni prima.
    public static let maximumSuspension: TimeInterval = 30 * 60
}

/// Esito di una sospensione.
public struct SuspensionReport: Codable, Sendable {
    public var suspended: [String]
    public var resumed: [String]
    public var expiresAt: Date?

    public init(suspended: [String] = [], resumed: [String] = [],
                expiresAt: Date? = nil) {
        self.suspended = suspended
        self.resumed = resumed
        self.expiresAt = expiresAt
    }
}


/// Fotografia dei processi piu' esosi, con CPU istantanea.
public struct ProcessSnapshot: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var pid: Int32
        public var cpuPercent: Double
        public var memoryMB: Double

        public init(name: String, pid: Int32, cpuPercent: Double, memoryMB: Double) {
            self.name = name
            self.pid = pid
            self.cpuPercent = cpuPercent
            self.memoryMB = memoryMB
        }
    }

    public var entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }
}
