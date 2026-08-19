import Foundation
import WattKit

/// Applica un `PowerProfile` al sistema.
///
/// Ogni operazione e' idempotente e ha un inverso esplicito: il Mac non deve
/// mai restare in uno stato che l'utente non sa come annullare. Se Watt
/// venisse disinstallato senza passare da `restoreAndCleanUp`, `Automatico`
/// da qualunque installazione successiva riporta comunque la baseline.
enum ProfileApplier {

    /// Raccoglie gli errori invece di fermarsi al primo: se Time Machine
    /// fallisce per mancanza di Full Disk Access non c'e' ragione di
    /// rinunciare anche a Low Power Mode e a Spotlight.
    struct Report {
        var failures: [String] = []
        var summary: String? { failures.isEmpty ? nil : failures.joined(separator: "; ") }
    }

    static func apply(_ profile: PowerProfile) -> Report {
        var report = Report()

        // Fotografa lo stato originale prima di qualunque modifica.
        let baseline = BaselineStore.captureIfNeeded { SystemReader.captureBaseline() }

        let plan = profile.plan
        if plan.restoreBaseline {
            restore(baseline, into: &report)
            return report
        }

        if let low = plan.lowPowerMode {
            setPmset("lowpowermode", low, &report)
        }
        if let nap = plan.powerNap {
            setPmset("powernap", nap, &report)
        }
        setSpotlightIndexing(enabled: !plan.pauseSpotlight,
                             baseline: baseline, &report)
        setTimeMachine(enabled: !plan.pauseTimeMachine,
                       baseline: baseline, &report)

        // Solo se lo stato desiderato differisce da quello in vigore:
        // rilanciare `taskpolicy` su tutti i daemon a ogni cambio di profilo
        // costava quasi dieci secondi per un clic, quasi sempre per non
        // cambiare nulla.
        if plan.demoteBackgroundDaemons != DemotionState.isDemoted {
            if plan.demoteBackgroundDaemons {
                demoteBackgroundDaemons(&report)
            } else {
                restoreBackgroundDaemons(&report)
            }
            DemotionState.isDemoted = plan.demoteBackgroundDaemons
        }

        if plan.purgeMemory {
            purgeMemory(&report)
        }

        return report
    }

    /// Se i daemon sono attualmente confinati sugli E-core.
    ///
    /// Persistito su file e non in memoria: l'helper esce dopo tre minuti di
    /// inattivita', e una variabile si perderebbe fra un cambio di profilo e
    /// il successivo, riportando il costo a ogni clic.
    enum DemotionState {
        private static let path = "/Library/Application Support/Watt/demoted"

        static var isDemoted: Bool {
            get { FileManager.default.fileExists(atPath: path) }
            set {
                if newValue {
                    try? FileManager.default.createDirectory(
                        atPath: (path as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: path, contents: nil)
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
    }

    static func restore(_ baseline: Baseline, into report: inout Report) {
        setPmset("lowpowermode", baseline.lowPowerMode, &report)
        setPmset("powernap", baseline.powerNap, &report)
        // `disablesleep` non viene piu' impostato da Watt (se ne occupa una
        // IOPMAssertion lato app), ma si ripristina comunque: una versione
        // precedente potrebbe averlo lasciato acceso.
        if baseline.sleepDisabled == false { setPmset("disablesleep", false, &report) }
        setSpotlightIndexing(enabled: baseline.spotlightIndexing,
                             baseline: baseline, &report, force: true)
        setTimeMachine(enabled: baseline.timeMachineAutomatic,
                       baseline: baseline, &report, force: true)
        if DemotionState.isDemoted {
            restoreBackgroundDaemons(&report)
            DemotionState.isDemoted = false
        }
    }

    // MARK: - Singole leve

    private static func setPmset(_ key: String, _ on: Bool,
                                 _ report: inout Report) {
        let result = CommandRunner.run(Tool.pmset, ["-a", key, on ? "1" : "0"])
        guard !result.succeeded else { return }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        report.failures.append("pmset \(key): \(detail.isEmpty ? "codice \(result.status)" : detail)")
    }

    /// Non riattiva Spotlight se era gia' disattivato dall'utente prima che
    /// Watt entrasse in scena: `Prestazioni` mette in pausa l'indicizzazione,
    /// ma `Automatico` non deve accenderla a chi l'aveva spenta apposta.
    private static func setSpotlightIndexing(enabled: Bool, baseline: Baseline,
                                             _ report: inout Report,
                                             force: Bool = false) {
        if enabled && !baseline.spotlightIndexing && !force { return }
        let target = enabled && (baseline.spotlightIndexing || force)
        let result = CommandRunner.run(Tool.mdutil,
                                       ["-a", "-i", target ? "on" : "off"])
        guard !result.succeeded else { return }
        report.failures.append("Spotlight: " + shortError(result))
    }

    private static func setTimeMachine(enabled: Bool, baseline: Baseline,
                                       _ report: inout Report,
                                       force: Bool = false) {
        if enabled && !baseline.timeMachineAutomatic && !force { return }
        let target = enabled && (baseline.timeMachineAutomatic || force)
        let result = CommandRunner.run(Tool.tmutil, [target ? "enable" : "disable"])
        guard !result.succeeded else { return }
        // `tmutil enable/disable` richiede Accesso completo al disco anche a
        // root. Se manca, si riporta il fatto invece di fingere successo.
        report.failures.append("Time Machine: " + shortError(result)
            + " (potrebbe servire Accesso completo al disco per l'helper)")
    }

    /// `taskpolicy -b` sposta il processo nel tier di throttling in
    /// background, che su Apple Silicon significa preferenza per gli E-core.
    /// Non uccide nulla e non impedisce al lavoro di completarsi: lo rende
    /// solo cedevole rispetto a cio' che hai in primo piano.
    private static func demoteBackgroundDaemons(_ report: inout Report) {
        let changed = setBackgroundTier("-b")
        if changed == 0 {
            report.failures.append("taskpolicy: nessun daemon degradato")
        }
    }

    private static func restoreBackgroundDaemons(_ report: inout Report) {
        _ = setBackgroundTier("-B")
    }

    /// Applica il flag a tutti i daemon noti trovati vivi e ritorna quanti
    /// ne ha effettivamente modificati.
    ///
    /// I fallimenti singoli si ignorano di proposito: questi processi
    /// nascono e muoiono in continuazione, e un `taskpolicy` che fallisce
    /// quasi sempre significa che il PID e' sparito fra la lettura della
    /// tabella e la chiamata. Conta solo che almeno uno sia stato preso.
    @discardableResult
    private static func setBackgroundTier(_ flag: String) -> Int {
        let table = CommandRunner.processTable()
        var changed = 0
        for name in BackgroundDaemons.names {
            for pid in table[name] ?? [] {
                let result = CommandRunner.run(
                    Tool.taskpolicy, [flag, "-p", String(pid)], timeout: 5)
                if result.succeeded { changed += 1 }
            }
        }
        return changed
    }

    /// Libera la memoria inattiva. Operazione una tantum e senza inverso:
    /// non tocca la baseline e non viene "annullata" da Automatico, perche'
    /// non c'e' nulla da annullare.
    static func purgeMemory(_ report: inout Report) {
        let result = CommandRunner.run(Tool.purge, [], timeout: 30)
        guard !result.succeeded else { return }
        report.failures.append("purge: " + shortError(result))
    }

    private static func shortError(_ result: CommandResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "codice \(result.status)" : text
    }
}
