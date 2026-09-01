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
                title: L("No bottleneck detected"),
                measured: sample?.pCoreSummary.map { L("P-cores at %@", $0) } ?? "",
                advice: L("The machine is running unrestricted. If something feels "
                        + "slow, the bottleneck is not in this Mac."),
                basis: nil), at: 0)
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    // MARK: - Singoli controlli

    private static func lowPowerMode(_ state: SystemState?) -> [Finding] {
        guard state?.lowPowerMode == true else { return [] }
        return [Finding(
            severity: .critical,
            title: L("Low Power Mode is on"),
            measured: L("power saving enabled"),
            advice: L("It is the only setting that genuinely lowers the clock, "
                    + "and it is easy to leave on without noticing: macOS "
                    + "offers it when the battery runs low."),
            basis: L("measured on this Mac: the same work took 10.68 s versus "
                   + "6.66 s, i.e. 60%% longer"),
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

            // La gravita' la decide quanto si sta muovendo, non quanto swap
            // risulta allocato: 8 GB fermi da ieri non rallentano niente.
            let heavy = (memory.swapOutRate ?? 0) > 8_388_608
                     || memory.pressureLevel >= 4
            findings.append(Finding(
                severity: heavy ? .critical : .warning,
                title: L("Not enough RAM: the system is writing to disk"),
                measured: memory.swapRateText.map {
                    L("%@ to swap now, %@ in use, %@ compressed",
                      $0, memory.swapText,
                      MemoryReader.Snapshot.gigabytes(memory.compressedBytes))
                } ?? L("%@ of swap in use, %@ compressed",
                       memory.swapText,
                       MemoryReader.Snapshot.gigabytes(memory.compressedBytes)),
                advice: L("Close what you do not need right now")
                      + (hogs.isEmpty ? "" : L(" — the largest are %@", hogs))
                      + L(". \"Free memory\" will not help here: purge discards "
                        + "the file cache, it does not bring back what has "
                        + "already been swapped out."),
                basis: L("reading a page from swap costs orders of magnitude more "
                       + "than from RAM, and no power profile moves it by a "
                       + "microsecond")))
        }

        if memory.pressureLevel >= 4 {
            findings.append(Finding(
                severity: .critical,
                title: L("Critical memory pressure"),
                measured: L("level %d reported by the kernel", Int(memory.pressureLevel)),
                advice: L("macOS is compressing and evicting pages just to stay "
                        + "afloat. This is the state where everything feels "
                        + "slow while the CPU looks idle."),
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
            title: L("Performance is being limited by heat"),
            measured: L("%.0f%% of maximum — %@",
                        fraction * 100, sample.pCoreSummary ?? ""),
            advice: L("No software can avoid this on a fanless Mac. You can only "
                    + "reduce the load, give it a break, or lift it off the "
                    + "desk so air can move under the chassis."),
            basis: L("measured: under sustained load this machine goes from "
                   + "3143 to 1188 MHz in about 90 seconds"))]
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
            title: L("Background processes are competing for the CPU"),
            measured: L("%.0f%% of CPU outside what you are using — %@", total, worst),
            advice: L("Freezing them stops them entirely, and they resume where "
                    + "they were when you go back to a normal profile."),
            basis: L("measured: with six competing processes the same work went "
                   + "from 7.4 to 12.5 s; freezing them brought it to 6.7 s"),
            remedy: .freezeServices)]
    }

    /// `WindowServer` alto significa che il costo è nel disegnare, non nel
    /// calcolare: è una diagnosi diversa e richiede un rimedio diverso.
    private static func compositing(_ processes: [ProcessSnapshot.Entry]) -> [Finding] {
        guard let server = processes.first(where: { $0.name == "WindowServer" }),
              server.cpuPercent >= 25 else { return [] }
        return [Finding(
            severity: server.cpuPercent >= 50 ? .warning : .info,
            title: L("Window compositing is using a lot of CPU"),
            measured: L("WindowServer at %.0f%%", server.cpuPercent),
            advice: L("Usually this means many windows, animations, transparency "
                    + "or a high-resolution external display. Reducing motion "
                    + "in Accessibility and closing unused windows matters "
                    + "more than any power profile."),
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
            title: L("Spotlight is indexing"),
            measured: L("%.0f%% of CPU, plus disk I/O", total),
            advice: L("During a build it chews through the very folders you are "
                    + "rewriting: DerivedData, node_modules, target. Pausing "
                    + "it frees CPU and disk at once."),
            basis: nil,
            remedy: .freezeServices)]
    }
}
