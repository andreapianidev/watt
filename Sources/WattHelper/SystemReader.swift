import Foundation
import WattKit

/// Lettura dello stato reale del sistema.
///
/// Tutto viene riletto dai tool di sistema invece di essere dedotto dal
/// profilo selezionato: se l'utente cambia Low Power Mode da Impostazioni di
/// Sistema, o un altro strumento mette in pausa Spotlight, la menu bar deve
/// dire la verita' e non quello che Watt crede di aver impostato.
enum SystemReader {

    /// Parsifica le sezioni di `pmset -g custom` in
    /// `["AC Power": ["lowpowermode": "0", ...], "Battery Power": [...]]`.
    static func pmsetCustom() -> [String: [String: String]] {
        let result = CommandRunner.run(Tool.pmset, ["-g", "custom"], timeout: 8)
        guard result.succeeded else { return [:] }

        var sections: [String: [String: String]] = [:]
        var current: String?
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasSuffix(":") && !line.hasPrefix(" ") {
                current = String(line.dropLast())
                sections[current!] = [:]
                continue
            }
            guard let section = current else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            // Chiavi come "Sleep On Power Button" hanno spazi: il valore e'
            // sempre l'ultimo campo, la chiave e' tutto il resto.
            let value = String(parts[parts.count - 1])
            let key = parts.dropLast().joined(separator: " ")
            sections[section]?[key] = value
        }
        return sections
    }

    /// Watt scrive sempre con `pmset -a`, quindi le due sezioni restano
    /// allineate; si legge AC Power come canonica e si ripiega su Battery.
    private static func pmsetFlag(_ key: String,
                                  in sections: [String: [String: String]]) -> Bool {
        let value = sections["AC Power"]?[key] ?? sections["Battery Power"]?[key]
        return value == "1"
    }

    static func sleepDisabled() -> Bool {
        let result = CommandRunner.run(Tool.pmset, ["-g"], timeout: 8)
        guard result.succeeded else { return false }
        for line in result.stdout.split(whereSeparator: \.isNewline)
        where line.contains("SleepDisabled") {
            return line.split(separator: " ").last == "1"
        }
        return false
    }

    static func spotlightIndexingEnabled() -> Bool {
        let result = CommandRunner.run(Tool.mdutil, ["-s", "/"], timeout: 8)
        guard result.succeeded else { return true }
        // "Indexing enabled." / "Indexing disabled." / "Indexing and searching
        // disabled." a seconda della versione di macOS.
        return !result.stdout.lowercased().contains("disabled")
    }

    static func timeMachineAutomatic() -> Bool {
        let result = CommandRunner.run(
            Tool.defaultsCmd,
            ["read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"],
            timeout: 8)
        guard result.succeeded else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// `appNapDisabled` non e' leggibile qui: vive nel dominio globale
    /// dell'utente, e questo processo gira come root. Lo compila l'app.
    static func currentState() -> SystemState {
        let sections = pmsetCustom()
        return SystemState(
            lowPowerMode: pmsetFlag("lowpowermode", in: sections),
            powerNap: pmsetFlag("powernap", in: sections),
            sleepDisabled: sleepDisabled(),
            spotlightIndexing: spotlightIndexingEnabled(),
            timeMachineAutomatic: timeMachineAutomatic(),
            appNapDisabled: false,
            helperVersion: WattHelperVersion.current)
    }

    static func captureBaseline() -> Baseline {
        let state = currentState()
        return Baseline(lowPowerMode: state.lowPowerMode,
                        powerNap: state.powerNap,
                        sleepDisabled: state.sleepDisabled,
                        spotlightIndexing: state.spotlightIndexing,
                        timeMachineAutomatic: state.timeMachineAutomatic,
                        appNapDisabled: false,
                        capturedAt: Date())
    }
}
