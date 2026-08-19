import Foundation
import Darwin

/// Tabella dei processi con CPU **istantanea**, letta via `libproc`.
///
/// Il `%CPU` di `ps` è la media sull'intera vita del processo, non il consumo
/// adesso: una shell che ha macinato per un'ora e ora è ferma continua a
/// dichiarare il 60%. Basare su quel numero la scelta di cosa rallentare
/// significa colpire processi già innocui e mancare quelli che stanno
/// consumando davvero.
///
/// Qui si campiona il tempo CPU accumulato in due istanti e si divide per il
/// tempo trascorso, che è la definizione di "quanto sta consumando ora".
/// Come effetto collaterale non si lancia nessun processo.
enum ProcessTable {

    struct Entry {
        var pid: Int32
        var parentPID: Int32
        var name: String
        var cpuPercent: Double
        var memoryMB: Double
    }

    /// - Parameter window: durata della finestra di misura. Sotto i 200 ms il
    ///   rumore di campionamento supera il segnale.
    static func sample(window: TimeInterval = 0.4) -> [Entry] {
        let first = cpuTimes()
        guard !first.isEmpty else { return [] }
        Thread.sleep(forTimeInterval: window)
        let second = cpuTimes()

        var entries: [Entry] = []
        entries.reserveCapacity(second.count)

        for (pid, later) in second {
            guard let earlier = first[pid] else { continue }
            let deltaNanos = later > earlier ? later - earlier : 0
            let percent = Double(deltaNanos) / (window * 1_000_000_000) * 100
            guard let info = info(for: pid) else { continue }
            entries.append(Entry(pid: pid,
                                 parentPID: info.parentPID,
                                 name: info.name,
                                 cpuPercent: percent,
                                 memoryMB: info.memoryMB))
        }
        return entries
    }

    // MARK: - libproc

    private static func allPIDs() -> [Int32] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [Int32](repeating: 0,
                           count: Int(byteCount) / MemoryLayout<Int32>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }
        return pids.filter { $0 > 0 }
    }

    /// Tempo CPU cumulato (utente + sistema) in nanosecondi, per PID.
    private static func cpuTimes() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        for pid in allPIDs() {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            result[pid] = usage.ri_user_time + usage.ri_system_time
        }
        return result
    }

    private static func info(for pid: Int32) -> (name: String, parentPID: Int32,
                                                 memoryMB: Double)? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize
        else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let memory = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            ? Double(task.pti_resident_size) / 1_048_576
            : 0

        let name = withUnsafeBytes(of: bsd.pbi_comm) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return (name, Int32(bsd.pbi_ppid), memory)
    }

    /// Nome leggibile di un processo.
    ///
    /// `pbi_comm` si ferma a sedici caratteri, e a quel punto "Code Helper
    /// (Renderer)" diventa "Code Helper (Re" e un binario versionato diventa
    /// "2.1.235": inutile da mostrare a chi deve decidere cosa chiudere. Il
    /// percorso completo dell'eseguibile da' il nome vero, e si risolve solo
    /// per i processi che vengono effettivamente riportati.
    static func displayName(for pid: Int32, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return fallback
        }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return fallback }

        // Per un'app in bundle il nome utile e' quello dell'app, non
        // dell'eseguibile annidato in Contents/MacOS.
        if let range = path.range(of: ".app/Contents/MacOS/") {
            let bundle = String(path[path.startIndex..<range.lowerBound])
            return (bundle as NSString).lastPathComponent
        }

        let basename = (path as NSString).lastPathComponent
        // Alcuni programmi installano l'eseguibile con il numero di versione
        // come nome del file: il percorso reale finisce in "2.1.235", che a
        // chi deve decidere cosa chiudere non dice nulla. In quel caso il
        // nome breve del processo e' piu' informativo del suo percorso.
        let hasLetters = basename.contains { $0.isLetter }
        return hasLetters ? basename : fallback
    }

    /// Catena degli antenati di un processo, fino a `launchd`.
    ///
    /// Serve a non rallentare mai la shell o il terminale da cui il comando è
    /// stato lanciato: sarebbe il primo effetto che l'utente noterebbe, e il
    /// più difficile da collegare alla causa.
    static func ancestors(of pid: Int32, in entries: [Entry]) -> Set<Int32> {
        let parents = entries.reduce(into: [Int32: Int32]()) { $0[$1.pid] = $1.parentPID }
        var chain: Set<Int32> = []
        var current = pid
        // Il limite di iterazioni protegge da un ciclo nella tabella, che non
        // dovrebbe esistere ma che bloccherebbe un demone root.
        for _ in 0..<64 {
            chain.insert(current)
            guard let parent = parents[current], parent > 1 else { break }
            current = parent
        }
        return chain
    }
}
