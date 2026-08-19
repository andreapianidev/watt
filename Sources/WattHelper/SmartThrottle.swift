import Foundation
import WattKit

/// Sceglie quali processi rallentare in base a quanto stanno consumando
/// davvero, invece che da una lista fissa compilata a priori.
///
/// La regola di sicurezza è una sola e non ammette eccezioni: **non si tocca
/// nulla che abbia un'interfaccia**. L'elenco dei PID protetti arriva
/// dall'app, che le applicazioni visibili le conosce; l'helper da solo non
/// potrebbe distinguerle, perché dal suo punto di vista Xcode che compila e
/// un daemon che indicizza sono entrambi soltanto processi che consumano.
enum SmartThrottle {

    private static let statePath = "/Library/Application Support/Watt/throttled.json"

    // MARK: - Applicazione

    static func throttleHeavyBackground(protectedPIDs: Set<Int32>) -> ThrottleReport {
        var report = ThrottleReport()

        let candidates = ProcessTable.sample()
        guard !candidates.isEmpty else {
            report.failure = "tabella dei processi illeggibile"
            return report
        }

        // Antenati dell'helper: la shell, il terminale o l'app da cui la
        // richiesta è partita non vanno mai toccati.
        var protectedSet = protectedPIDs
        protectedSet.formUnion(
            ProcessTable.ancestors(of: getpid(), in: candidates))

        // Anche i figli delle applicazioni protette: un processo di supporto
        // di Xcode o del browser è parte di ciò con cui stai lavorando, anche
        // se non ha una finestra propria.
        for entry in candidates where protectedSet.contains(entry.parentPID) {
            protectedSet.insert(entry.pid)
        }

        var throttledPIDs: [Int32] = []
        for candidate in candidates {
            if protectedSet.contains(candidate.pid) {
                continue
            }
            if ProtectedProcesses.names.contains(candidate.name) {
                report.skipped.append(candidate.name)
                continue
            }
            // La lista fissa dei daemon differibili resta valida a
            // prescindere dal consumo istantaneo: `mds` che indicizza a
            // singhiozzo va confinato lo stesso, perché il problema è l'I/O
            // che genera, non la CPU che mostra in quel decimo di secondo.
            let isKnownDeferrable = BackgroundDaemons.names.contains(candidate.name)
            guard isKnownDeferrable
                    || candidate.cpuPercent >= ProtectedProcesses.minimumCPUPercent
            else { continue }

            let result = CommandRunner.run(
                Tool.taskpolicy, ["-b", "-p", String(candidate.pid)], timeout: 5)
            guard result.succeeded else { continue }

            throttledPIDs.append(candidate.pid)
            report.throttled.append(ThrottleReport.Entry(
                name: candidate.name, pid: candidate.pid,
                cpuPercent: candidate.cpuPercent, memoryMB: candidate.memoryMB))
        }

        // I PID vengono persistiti perché l'helper esce dopo tre minuti di
        // inattività: senza, non resterebbe traccia di cosa ripristinare.
        persist(throttledPIDs, in: candidates)
        report.throttled.sort { $0.cpuPercent > $1.cpuPercent }
        return report
    }

    static func restoreThrottled() -> String? {
        let stored = loadPersisted()
        guard !stored.isEmpty else { return nil }

        // I PID possono essere stati riciclati da altri processi nel
        // frattempo: si riapplica la priorità normale solo a quelli ancora
        // vivi con lo stesso nome di quando furono rallentati.
        let alive = ProcessTable.sample(window: 0.05)
            .reduce(into: [Int32: String]()) { $0[$1.pid] = $1.name }
        for (pid, name) in stored where alive[pid] == name {
            CommandRunner.run(Tool.taskpolicy, ["-B", "-p", String(pid)], timeout: 5)
        }
        try? FileManager.default.removeItem(atPath: statePath)
        return nil
    }

    // MARK: - Persistenza

    private static func persist(_ pids: [Int32], in entries: [ProcessTable.Entry]) {
        let table = entries.reduce(into: [Int32: String]()) { $0[$1.pid] = $1.name }
        let payload = pids.compactMap { pid -> [String: String]? in
            guard let name = table[pid] else { return nil }
            return ["pid": String(pid), "name": name]
        }
        try? FileManager.default.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private static func loadPersisted() -> [(Int32, String)] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let payload = try? JSONSerialization.jsonObject(with: data)
                as? [[String: String]]
        else { return [] }
        return payload.compactMap { entry in
            guard let pid = entry["pid"].flatMap(Int32.init),
                  let name = entry["name"] else { return nil }
            return (pid, name)
        }
    }
}
