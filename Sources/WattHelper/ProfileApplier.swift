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

        if plan.demoteBackgroundDaemons {
            demoteBackgroundDaemons(&report)
        } else {
            restoreBackgroundDaemons(&report)
        }

        return report
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
        restoreBackgroundDaemons(&report)
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
        var failed: [String] = []
        for name in BackgroundDaemons.names {
            for pid in CommandRunner.pids(forProcessNamed: name) {
                let result = CommandRunner.run(
                    Tool.taskpolicy, ["-b", "-p", String(pid)], timeout: 5)
                if !result.succeeded { failed.append("\(name)(\(pid))") }
            }
        }
        // I daemon rinascono in continuazione: un fallimento isolato quasi
        // sempre significa che il processo e' morto fra `pgrep` e
        // `taskpolicy`. Si segnala solo se fallisce l'intera lista.
        if failed.count == BackgroundDaemons.names.count && !failed.isEmpty {
            report.failures.append("taskpolicy: nessun daemon degradato")
        }
    }

    private static func restoreBackgroundDaemons(_ report: inout Report) {
        for name in BackgroundDaemons.names {
            for pid in CommandRunner.pids(forProcessNamed: name) {
                CommandRunner.run(Tool.taskpolicy,
                                  ["-B", "-p", String(pid)], timeout: 5)
            }
        }
    }

    private static func shortError(_ result: CommandResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "codice \(result.status)" : text
    }
}
