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
