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
    @discardableResult
    static func run(_ launchPath: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 20) -> CommandResult {
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
            return CommandResult(status: -2, stdoutData: Data(),
                                 stderr: "timeout dopo \(Int(timeout))s")
        }
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            status: process.terminationStatus,
            stdoutData: collected.stdout,
            stderr: String(decoding: collected.stderr, as: UTF8.self))
    }

    /// PID vivi per un nome di processo esatto.
    static func pids(forProcessNamed name: String) -> [pid_t] {
        let result = run(Tool.pgrep, ["-x", name], timeout: 5)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
