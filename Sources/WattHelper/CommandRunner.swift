import Foundation

/// Esecuzione di comandi di sistema con percorsi assoluti.
///
/// I percorsi sono costanti assolute e mai composte a partire da input
/// esterni: un helper root che risolvesse i binari via `PATH` sarebbe
/// dirottabile con una variabile d'ambiente.
enum Tool {
    static let pmset      = "/usr/bin/pmset"
    static let mdutil     = "/usr/bin/mdutil"
    static let tmutil     = "/usr/bin/tmutil"
    static let taskpolicy = "/usr/sbin/taskpolicy"
    static let powermetrics = "/usr/bin/powermetrics"
    static let defaultsCmd = "/usr/bin/defaults"
    static let pgrep      = "/usr/bin/pgrep"
    static let ps         = "/bin/ps"
    static let purge      = "/usr/sbin/purge"
}

struct CommandResult {
    let status: Int32
    /// Output grezzo. `powermetrics --format plist` separa i documenti con
    /// byte NUL, che una conversione a `String` renderebbe scomodi da
    /// isolare: il chiamante che deve parsare plist usa questo.
    let stdoutData: Data
    let stderr: String
    var succeeded: Bool { status == 0 }
    var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
}

/// I due pipe vengono letti da thread distinti; il buffer condiviso passa
/// da un lock invece che da variabili catturate, cosi' la lettura e' anche
/// formalmente corretta sotto strict concurrency.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setStdout(_ data: Data) { lock.lock(); out = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); err = data; lock.unlock() }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
}

enum CommandRunner {

    /// Serializza **ogni** esecuzione di comandi dell'helper.
    ///
    /// `fork`/`exec` concorrenti dallo stesso processo si portano dietro una
    /// gara classica sui descrittori: mentre un figlio viene creato, eredita
    /// gli estremi in scrittura dei pipe di un altro che sta partendo nello
    /// stesso istante. Il lettore di quel pipe non vede mai EOF e resta
    /// bloccato fino al timeout, con zero byte letti, anche se il comando e'
    /// terminato regolarmente.
    ///
    /// Succedeva in concreto quando l'app in barra dei menu chiedeva un
    /// campione di `powermetrics` mentre l'helper stava applicando un
    /// profilo, cioe' lanciando `ps` e decine di `taskpolicy`. Un lock e'
    /// sufficiente: questi comandi durano al massimo qualche secondo e non
    /// c'e' nulla da guadagnare a sovrapporli.
    private static let executionLock = NSLock()

    @discardableResult
    static func run(_ launchPath: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 20) -> CommandResult {
        executionLock.lock()
        defer { executionLock.unlock() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // Ambiente minimo: nessuna variabile ereditata puo' influenzare
        // il comportamento dei tool invocati da root.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdoutData: Data(),
                                 stderr: "avvio fallito: \(error.localizedDescription)")
        }

        // Legge i pipe su thread separati: `powermetrics` produce abbastanza
        // output da riempire il buffer del pipe, e aspettare l'uscita del
        // processo prima di leggere lo bloccherebbe in un deadlock.
        let collected = OutputBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "watt.helper.pipe", attributes: .concurrent)
        group.enter()
        queue.async {
            collected.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        queue.async {
            collected.setStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            // Anche in timeout si restituisce quello che il comando ha
            // effettivamente scritto: buttarlo via nasconde proprio il
            // messaggio che spiega perche' si e' bloccato.
            let partial = String(decoding: collected.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(
                status: -2,
                stdoutData: collected.stdout,
                stderr: "timeout dopo \(Int(timeout))s"
                      + (partial.isEmpty ? "" : " | stderr: \(partial)"))
        }
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            status: process.terminationStatus,
            stdoutData: collected.stdout,
            stderr: String(decoding: collected.stderr, as: UTF8.self))
    }

    /// PID vivi, raggruppati per nome di processo.
    ///
    /// Una sola invocazione di `ps` per tutta la tabella dei processi invece
    /// di un `pgrep` per ciascun nome cercato: con una ventina di daemon da
    /// individuare la differenza non e' cosmetica, sono venti fork in meno e
    /// diversi secondi risparmiati a ogni applicazione del profilo.
    static func processTable() -> [String: [pid_t]] {
        let result = run(Tool.ps, ["-Ac", "-o", "pid=,comm="], timeout: 10)
        guard result.succeeded else { return [:] }

        var table: [String: [pid_t]] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex..<space])
            else { continue }
            // `-c` fa stampare a ps il solo nome eseguibile, senza percorso
            // ne' argomenti: e' gia' la forma con cui confrontare.
            let name = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            table[name, default: []].append(pid)
        }
        return table
    }
}
