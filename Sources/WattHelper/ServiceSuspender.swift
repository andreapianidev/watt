import Foundation
import Darwin
import WattKit

/// Congela e riattiva i servizi di sistema differibili.
///
/// `taskpolicy -b` sposta un processo in coda, `SIGSTOP` lo ferma del tutto:
/// finché non arriva `SIGCONT` non viene schedulato nemmeno per un ciclo. È
/// la differenza fra dare meno priorità a Spotlight e non farlo girare
/// affatto.
///
/// Ogni sospensione porta con sé una scadenza. Se Watt muore mentre tiene
/// fermi dei servizi, la prima invocazione successiva dell'helper li
/// riattiva: senza, resterebbero congelati fino al riavvio e nessuno
/// collegherebbe mai Spotlight che non indicizza più a un'app chiusa il
/// giorno prima.
enum ServiceSuspender {

    private static let statePath = "/Library/Application Support/Watt/suspended.json"

    private struct State: Codable {
        var pids: [Int32]
        var names: [String]
        var startedAt: Date
        var expiresAt: Date
    }

    // MARK: - Sospensione

    static func suspend() -> SuspensionReport {
        resumeIfExpired()

        let table = ProcessTable.sample(window: 0.05)
        var suspendedPIDs: [Int32] = []
        var suspendedNames: [String] = []

        for entry in table where SuspendableServices.names.contains(entry.name) {
            // `kill` con SIGSTOP: nessun processo da lanciare, e l'esito è
            // immediato invece che affidato al parsing dell'output di un tool.
            guard kill(entry.pid, SIGSTOP) == 0 else { continue }
            suspendedPIDs.append(entry.pid)
            suspendedNames.append(entry.name)
        }

        guard !suspendedPIDs.isEmpty else { return SuspensionReport() }

        let expiry = Date().addingTimeInterval(SuspendableServices.maximumSuspension)
        persist(State(pids: suspendedPIDs, names: suspendedNames,
                      startedAt: Date(), expiresAt: expiry))
        NSLog("[Watt] sospesi %d servizi fino a %@",
              suspendedPIDs.count, expiry as NSDate)

        return SuspensionReport(
            suspended: Array(Set(suspendedNames)).sorted(),
            expiresAt: expiry)
    }

    // MARK: - Ripresa

    @discardableResult
    static func resume() -> SuspensionReport {
        guard let state = loadState() else { return SuspensionReport() }

        // Un PID può essere stato riciclato da un altro processo nel
        // frattempo: si manda SIGCONT solo a chi porta ancora lo stesso nome.
        let alive = ProcessTable.sample(window: 0.05)
            .reduce(into: [Int32: String]()) { $0[$1.pid] = $1.name }

        var resumed: [String] = []
        for (pid, name) in zip(state.pids, state.names) where alive[pid] == name {
            if kill(pid, SIGCONT) == 0 { resumed.append(name) }
        }
        try? FileManager.default.removeItem(atPath: statePath)
        NSLog("[Watt] riattivati %d servizi", resumed.count)
        return SuspensionReport(resumed: Array(Set(resumed)).sorted())
    }

    /// Riattiva se la sospensione ha superato la sua scadenza.
    /// Va chiamata a ogni avvio dell'helper.
    static func resumeIfExpired() {
        guard let state = loadState() else { return }
        guard Date() >= state.expiresAt else { return }
        NSLog("[Watt] sospensione scaduta, riattivo")
        resume()
    }

    static var isSuspended: Bool { loadState() != nil }

    // MARK: - Persistenza

    private static func persist(_ state: State) {
        try? FileManager.default.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private static func loadState() -> State? {
        guard let data = FileManager.default.contents(atPath: statePath) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }
}
