import Foundation
import IOKit.pwr_mgt
import WattKit

/// Impedisce al Mac di addormentarsi, alla maniera di Amphetamine.
///
/// Le assertion IOKit muoiono con il processo: se Watt viene chiuso o va in
/// crash, il Mac torna da solo alle sue impostazioni. Non c'e' nessuno stato
/// persistente da ripulire, e nessun modo di lasciare la macchina sveglia
/// per sempre per sbaglio.
@MainActor
final class KeepAwake {

    enum Mode: Equatable, Codable {
        case off
        /// Finche' non lo si disattiva a mano.
        case indefinite
        /// Fino a una scadenza.
        case duration(TimeInterval)
        /// Finche' e' in corso una build o un altro lavoro pesante.
        case whileBuilding

        var label: String {
            switch self {
            case .off:           return L("Off")
            case .indefinite:    return L("Always on")
            case .whileBuilding: return L("While building")
            case .duration(let seconds):
                let minutes = Int(seconds / 60)
                if minutes % 60 == 0 {
                    let hours = minutes / 60
                    return hours == 1 ? L("1 hour") : L("%d hours", hours)
                }
                return L("%d minutes", minutes)
            }
        }
    }

    /// Processi la cui presenza indica una build in corso.
    ///
    /// Deliberatamente ristretta a strumenti **inequivocabili**. La versione
    /// precedente includeva `python3`, `node`, `go`, `java`, `make`: nomi
    /// generici che su una macchina da sviluppo sono quasi sempre vivi per
    /// qualche altra ragione, per cui il Mac non si sarebbe addormentato
    /// mai. Per una funzione il cui scopo e' lasciarlo dormire quando non
    /// serve, era il difetto peggiore possibile.
    ///
    /// Meglio un falso negativo, che costa una sospensione durante una build
    /// rara, di un falso positivo che rende la modalita' inutile sempre.
    static let buildProcesses = [
        // Compilatori e linker invocati solo da una build vera.
        "xcodebuild", "swift-frontend", "swift-driver", "swiftc",
        "ld-classic", "lto-prelink",
        // Sistemi di build.
        "ninja", "gradle-launcher", "xcodebuild-worker",
        // Toolchain con nomi propri.
        "cargo", "rustc", "tsc", "esbuild", "webpack",
        // Contenitori e virtualizzazione.
        "qemu-system-aarch64", "com.docker.build",
        // Elaborazione multimediale lunga.
        "ffmpeg", "HandBrakeCLI", "compressor",
    ]

    private var systemAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var holdsSystem = false
    private var holdsDisplay = false

    private var expiry: Date?
    private var ticker: Timer?

    private(set) var mode: Mode = .off
    /// Se `true` tiene acceso anche lo schermo, non solo il sistema.
    var keepDisplayOn = false {
        didSet { if oldValue != keepDisplayOn { refresh() } }
    }

    var onChange: (() -> Void)?

    /// Processo che sta attualmente tenendo sveglio il Mac in modalita'
    /// `whileBuilding`, da mostrare all'utente: senza, la modalita' sarebbe
    /// una scatola nera che a volte tiene sveglio e a volte no.
    private(set) var detectedProcess: String?

    var isActive: Bool { holdsSystem }

    var remaining: TimeInterval? {
        guard let expiry else { return nil }
        return max(0, expiry.timeIntervalSinceNow)
    }

    // MARK: - Controllo

    func set(_ newMode: Mode) {
        mode = newMode
        switch newMode {
        case .duration(let seconds):
            expiry = Date().addingTimeInterval(seconds)
        case .off, .indefinite, .whileBuilding:
            expiry = nil
        }
        refresh()
        scheduleTicker()
    }

    /// Rivaluta se le assertion vanno tenute o rilasciate.
    private func refresh() {
        let wanted: Bool
        switch mode {
        case .off:
            wanted = false
        case .indefinite:
            wanted = true
        case .duration:
            wanted = (remaining ?? 0) > 0
        case .whileBuilding:
            detectedProcess = Self.runningBuildProcess()
            wanted = detectedProcess != nil
        }

        setSystem(wanted)
        setDisplay(wanted && keepDisplayOn)
        onChange?()
    }

    /// Un solo timer per scadenza e rilevamento build. Gira solo quando c'e'
    /// qualcosa da sorvegliare: a modalita' spenta non resta nulla acceso.
    private func scheduleTicker() {
        ticker?.invalidate()
        ticker = nil
        guard mode != .off, mode != .indefinite else { return }

        let interval: TimeInterval = (mode == .whileBuilding) ? 10 : 1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        if case .duration = mode, (remaining ?? 0) <= 0 {
            set(.off)
            return
        }
        refresh()
    }

    // MARK: - Assertion

    private func setSystem(_ active: Bool) {
        guard active != holdsSystem else { return }
        if active {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Watt: \(mode.label)" as CFString,
                &systemAssertion)
            holdsSystem = (status == kIOReturnSuccess)
        } else {
            IOPMAssertionRelease(systemAssertion)
            holdsSystem = false
        }
    }

    private func setDisplay(_ active: Bool) {
        guard active != holdsDisplay else { return }
        if active {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Watt: schermo acceso" as CFString,
                &displayAssertion)
            holdsDisplay = (status == kIOReturnSuccess)
        } else {
            IOPMAssertionRelease(displayAssertion)
            holdsDisplay = false
        }
    }

    /// Primo processo di build trovato in esecuzione, se c'e'.
    private static func runningBuildProcess() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // `-x` richiede il nome esatto: senza, "go" o "make" farebbero da
        // sottostringa a mezzo sistema e il Mac non dormirebbe mai piu'.
        process.arguments = ["-x"] + buildProcesses
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let pid = String(decoding: data, as: UTF8.self)
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        return name(ofPID: String(pid))
    }

    private static func name(ofPID pid: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pid, "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }

    deinit {
        if holdsSystem { IOPMAssertionRelease(systemAssertion) }
        if holdsDisplay { IOPMAssertionRelease(displayAssertion) }
    }
}
