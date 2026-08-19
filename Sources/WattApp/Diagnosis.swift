import Foundation
import WattKit

/// Diagnosi di cosa sta *realmente* limitando la macchina in questo momento.
///
/// È la ragione per cui questa app esiste. Un selettore di profili su un Mac
/// senza ventola vale, misurato, lo 0,1%: il valore non è nel cambiare
/// impostazione, è nel sapere quale delle cinque cause possibili ti sta
/// rallentando adesso, perché quattro volte su cinque non è quella che
/// immagini.
///
/// Ogni verdetto porta con sé la base su cui poggia. Un consiglio senza un
/// numero dietro è un'opinione, e di opinioni sulle prestazioni ce ne sono già
/// abbastanza in giro.
struct Diagnosis {

    enum Severity: Int, Comparable {
        case ok, info, warning, critical
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var symbolName: String {
            switch self {
            case .ok:       return "checkmark.circle.fill"
            case .info:     return "info.circle"
            case .warning:  return "exclamationmark.triangle.fill"
            case .critical: return "exclamationmark.octagon.fill"
            }
        }

        var marker: String {
            switch self {
            case .ok:       return "OK "
            case .info:     return "·  "
            case .warning:  return "!  "
            case .critical: return "!! "
            }
        }
    }

    /// Azione che l'app può eseguire per rimediare, se ne esiste una.
    enum Remedy {
        case switchProfile(PowerProfile)
        case freezeServices
        case throttleBackground
        case none
    }

    struct Finding {
        var severity: Severity
        var title: String
        /// Il dato misurato che ha fatto scattare il verdetto.
        var measured: String
        var advice: String
        /// Su cosa poggia la stima del guadagno. `nil` quando non c'è una
        /// misura a sostegno, e in quel caso il consiglio non promette numeri.
        var basis: String?
        var remedy: Remedy = .none
    }

    // MARK: - Analisi

    static func analyze(sample: PowerSample?,
                        memory: MemoryReader.Snapshot?,
                        state: SystemState?,
                        processes: [ProcessSnapshot.Entry],
                        foregroundPIDs: Set<Int32>) -> [Finding] {
        var findings: [Finding] = []

        findings.append(contentsOf: lowPowerMode(state))
        findings.append(contentsOf: memoryPressure(memory, processes))
        findings.append(contentsOf: thermal(sample))
        findings.append(contentsOf: contention(processes, foregroundPIDs))
        findings.append(contentsOf: compositing(processes))
        findings.append(contentsOf: indexing(state, processes))

        if findings.allSatisfy({ $0.severity <= .info }) {
            findings.insert(Finding(
                severity: .ok,
                title: "Nessun collo di bottiglia rilevato",
                measured: sample?.pCoreSummary.map { "P-core a \($0)" } ?? "",
                advice: "La macchina sta girando senza limitazioni. Se un "
                      + "lavoro ti sembra lento, il collo di bottiglia non è "
                      + "in questa macchina.",
                basis: nil), at: 0)
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    // MARK: - Singoli controlli

    private static func lowPowerMode(_ state: SystemState?) -> [Finding] {
        guard state?.lowPowerMode == true else { return [] }
        return [Finding(
            severity: .critical,
            title: "Low Power Mode è attivo",
            measured: "risparmio energetico acceso",
            advice: "È l'unica impostazione che abbassa davvero il clock, ed è "
                  + "facile lasciarla accesa senza accorgersene: macOS la "
                  + "propone quando la batteria scende.",
            basis: "misurato su questo Mac: stesso lavoro in 10,68 s contro "
                 + "6,66 s, cioè il 60% in più",
            remedy: .switchProfile(.automatico))]
    }

    /// Lo swap è il controllo più importante per chi compila, e quello che
    /// nessun profilo energetico può risolvere.
    private static func memoryPressure(
        _ memory: MemoryReader.Snapshot?,
        _ processes: [ProcessSnapshot.Entry]
    ) -> [Finding] {
        guard let memory else { return [] }
        var findings: [Finding] = []

        if memory.isSwapping {
            // Solo processi che occupano abbastanza da valere la chiusura:
            // suggerire di chiudere qualcosa da 40 MB e' rumore.
            let hogs = processes
                .filter { $0.memoryMB >= 300 }
                .sorted { $0.memoryMB > $1.memoryMB }
                .prefix(3)
                .map { String(format: "%@ (%.1f GB)", $0.name, $0.memoryMB / 1024) }
                .joined(separator: ", ")

            findings.append(Finding(
                severity: memory.swapUsedBytes > 4_294_967_296 ? .critical : .warning,
                title: "La RAM non basta: il sistema sta scrivendo su disco",
                measured: "\(memory.swapText) di swap in uso, "
                        + "\(MemoryReader.Snapshot.gigabytes(memory.compressedBytes)) compressi",
                advice: "Chiudi ciò che non ti serve adesso"
                      + (hogs.isEmpty ? "" : " — i più ingombranti sono \(hogs)")
                      + ". «Libera memoria» non aiuta in questo caso: purge "
                      + "scarta la cache dei file, non riporta in RAM ciò che "
                      + "è già finito sullo swap.",
                basis: "una pagina letta dallo swap costa ordini di grandezza "
                     + "più di una in RAM, e nessun profilo energetico la "
                     + "sposta di un microsecondo"))
        }

        if memory.pressureLevel >= 4 {
            findings.append(Finding(
                severity: .critical,
                title: "Pressione di memoria critica",
                measured: "livello \(memory.pressureLevel) riportato dal kernel",
                advice: "macOS sta comprimendo e sfrattando pagine per stare "
                      + "in piedi. È la condizione in cui tutto diventa lento "
                      + "senza che la CPU risulti occupata.",
                basis: nil))
        }
        return findings
    }

    private static func thermal(_ sample: PowerSample?) -> [Finding] {
        guard let sample else { return [] }
        let pressure = sample.thermalPressure
        guard pressure.demandsAttention else { return [] }

        // `ProcessInfo` segnala "fair" gia' sotto un carico normale, e a quel
        // punto i core stanno ancora girando quasi al massimo. Allarmarsi li'
        // renderebbe l'avviso rumore di fondo: si richiede che il clock sia
        // davvero sceso, oppure che la pressione sia grave.
        let fraction = sample.pCoreCeilingFraction ?? 1
        return [Finding(
            severity: fraction < 0.6 ? .critical : .warning,
            title: "Le prestazioni sono limitate dal calore",
            measured: String(format: "%.0f%% del massimo — %@",
                             fraction * 100, sample.pCoreSummary ?? ""),
            advice: "Non esiste software che lo eviti su un Mac senza ventola. "
                  + "Puoi solo ridurre il carico, dargli tregua, o sollevarlo "
                  + "dal piano per far circolare aria sotto la scocca.",
            basis: "misurato: sotto carico prolungato questa macchina passa da "
                 + "3143 a 1188 MHz in circa 90 secondi")]
    }

    /// Contesa vera: processi che consumano CPU e che non sono ciò con cui
    /// stai lavorando.
    private static func contention(_ processes: [ProcessSnapshot.Entry],
                                   _ foreground: Set<Int32>) -> [Finding] {
        let background = processes.filter {
            !foreground.contains($0.pid)
                && !ProtectedProcesses.names.contains($0.name)
                && $0.cpuPercent >= 3
        }
        let total = background.map(\.cpuPercent).reduce(0, +)
        guard total >= 20 else { return [] }

        let worst = background.prefix(3)
            .map { String(format: "%@ %.0f%%", $0.name, $0.cpuPercent) }
            .joined(separator: ", ")

        return [Finding(
            severity: total >= 60 ? .critical : .warning,
            title: "Processi in background stanno competendo per la CPU",
            measured: String(format: "%.0f%% di CPU fuori da ciò che stai usando — %@",
                             total, worst),
            advice: "Congelarli li ferma del tutto, e riprendono da dove erano "
                  + "quando torni a un profilo normale.",
            basis: "misurato: con sei processi in competizione lo stesso lavoro "
                 + "passava da 7,4 a 12,5 s; congelandoli tornava a 6,7 s",
            remedy: .freezeServices)]
    }

    /// `WindowServer` alto significa che il costo è nel disegnare, non nel
    /// calcolare: è una diagnosi diversa e richiede un rimedio diverso.
    private static func compositing(_ processes: [ProcessSnapshot.Entry]) -> [Finding] {
        guard let server = processes.first(where: { $0.name == "WindowServer" }),
              server.cpuPercent >= 25 else { return [] }
        return [Finding(
            severity: server.cpuPercent >= 50 ? .warning : .info,
            title: "La composizione grafica sta consumando parecchio",
            measured: String(format: "WindowServer al %.0f%%", server.cpuPercent),
            advice: "Di solito significa molte finestre, animazioni, "
                  + "trasparenze o un display esterno ad alta risoluzione. "
                  + "Ridurre il movimento in Accessibilità e chiudere finestre "
                  + "inutilizzate incide più di qualunque profilo energetico.",
            basis: nil)]
    }

    private static func indexing(_ state: SystemState?,
                                 _ processes: [ProcessSnapshot.Entry]) -> [Finding] {
        let indexers = processes.filter {
            ["mds", "mds_stores", "mdworker_shared"].contains($0.name)
                && $0.cpuPercent >= 5
        }
        guard !indexers.isEmpty else { return [] }
        let total = indexers.map(\.cpuPercent).reduce(0, +)
        return [Finding(
            severity: .warning,
            title: "Spotlight sta indicizzando",
            measured: String(format: "%.0f%% di CPU, più I/O sul disco", total),
            advice: "Durante una build macina proprio le cartelle che stai "
                  + "riscrivendo: DerivedData, node_modules, target. "
                  + "Metterlo in pausa toglie CPU e disco insieme.",
            basis: nil,
            remedy: .freezeServices)]
    }
}
